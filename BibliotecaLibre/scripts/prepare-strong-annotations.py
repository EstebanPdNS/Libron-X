#!/usr/bin/env python3
"""Project only Strong numbers, excluding the source's separate morphology layer."""
import base64
import copy
import importlib.util
from pathlib import Path
import re
import shutil
import sqlite3
import sys

spec=importlib.util.spec_from_file_location('organization',Path(__file__).with_name('organize-library.py'))
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o)
library=Path(sys.argv[1]).resolve();output=Path(sys.argv[2]);catalog=o.json.loads((library/'catalog.json').read_text());resources=catalog['resources']
visibility_path=Path.home()/'Library/Application Support/org.libronx.mac.rebuild/hidden-resources.json';visibility=o.json.loads(visibility_path.read_text());hidden={r['id'] for r in visibility['hidden']}


def plain(text, morphology):
    text=re.sub(r'<tvm\b[^>]*>.*?</tvm>','',text,flags=re.I|re.S)
    if morphology:
        def remove(match):
            token=match[2].strip(',')
            is_code = token in ['C','P','B','T','Pu','Pb','Cc','Ca','Ce','Co','Pn','Pr','Pt','AgT','AnT'] or re.fullmatch(r'(?:[ADNPRTVX][A-Z0-9-]+|N[CP][a-zA-Z0-9-]*|V[qphntvQ][A-Z][A-Za-z0-9-]*|R[FBDA][a-zA-Z0-9-]*)',token)
            return match[1]+' ' if is_code else match[0]
        for _ in range(5):text=re.sub(r'(</num>)\s+([A-Za-z0-9,-]+)',remove,text)
        text=text.replace('•','')
    text=o.html.unescape(re.sub(r'<[^>]+>','',text))
    if morphology:
        text=re.sub(r'\b(?:N[CP][A-Za-z0-9-]+|[A-Z]{2}[a-z][A-Za-z0-9-]*|V[a-z][A-Z][A-Za-z0-9-]*|[NRVADP][A-Z-]*\d[A-Z0-9-]*|[NDAPR][NGDAV][SPD][MFN])\b','',text)
    return re.sub(r'[ \t]+',' ',text).strip()


def rtf(text):
    def escape(value):
        parts=[]
        for character in value:
            if character in '\\{}':parts.append('\\'+character)
            elif character=='\n':parts.append('\\par\n')
            elif 32<=ord(character)<127:parts.append(character)
            else:
                data=character.encode('utf-16-le')
                for i in range(0,len(data),2):
                    unit=int.from_bytes(data[i:i+2],'little');parts.append('\\u'+str(unit if unit<32768 else unit-65536)+'?')
        return ''.join(parts)
    body=[];last=0
    for match in re.finditer(r'[HG]\d+',text):
        body.append(escape(text[last:match.start()]));body.append('{\\fs16\\super\\cf1 '+escape(match[0])+'}');last=match.end()
    body.append(escape(text[last:]))
    return base64.b64encode(('{\\rtf1\\ansi\\uc1{\\fonttbl{\\f0 Times New Roman;}}{\\colortbl;\\red0\\green122\\blue255;}\\f0\\fs24 '+''.join(body)+'}').encode()).decode()


receipt=[]
for base in list(resources):
    evidence=next((e for e in base.get('libron',{}).get('evidence',[]) if e['field']=='strongVariantPackage'),None)
    if evidence is None:continue
    original=Path(evidence['value']);m=o.json.loads((original/'manifest.json').read_text())
    # Reruns use the immutable source pointer, never the already projected text.
    if (original/'annotation-source.json').exists():
        original=Path(o.json.loads((original/'annotation-source.json').read_text())['package']);m=o.json.loads((original/'manifest.json').read_text())
    identity='/libron/strong-annotations/'+m['payload']['sha256']
    target=library/(base['title']+' — anotaciones Strong — '+m['payload']['sha256'][:16]+'.libron')
    if target.exists() and '--refresh' in sys.argv[3:]:
        backup=output/'previous-strong-annotation-projection';backup.mkdir(exist_ok=True)
        assert not (backup/target.name).exists()
        target.rename(backup/target.name)
    if not target.exists():
        shutil.copytree(original,target)
        db=sqlite3.connect(target/'normalized/reader.sqlite');header=o.get(db,'header');header['resourceID']=identity
        book_keys={i:b for i,b in db.execute('SELECT ordinal,book FROM bible_v1')};db.execute('DELETE FROM bible_v1')
        raw=sqlite3.connect(original/m['payload']['path']);groups={}
        for b,c,v,text in raw.execute('SELECT Book,Chapter,Verse,Scripture FROM Bible ORDER BY Book,Chapter,Verse'):
            groups.setdefault((b,c),[]).append((v,plain(text, '1960' in base['title'])))
        assert len(groups)==header['sectionCount']
        for ordinal,((book,chapter),verses) in enumerate(groups.items()):
            parts=[];anchors=[];offset=0
            for verse,text in verses:
                code=o.BOOKS[book-1] if book in range(1,67) else f'Book {book}';reference=f'{code} {chapter}:{verse}'
                anchors.append({'characterOffset':offset,'dataTypeCode':0,'decodedOffset':0,'flags':0,'reference':reference})
                db.execute('INSERT INTO bible_v1 VALUES(?,?,?,?,?,?)',(book_keys[ordinal],chapter,verse,ordinal,offset,reference))
                line=f'{verse} {text}\n';parts.append(line);offset+=len(line.encode('utf-16-le'))//2
            text=''.join(parts)
            content={'anchors':anchors,'descriptor':{'ordinal':ordinal,'headerOffset':0,'payloadOffset':0,'storedLength':0,'decodedLength':offset,'mode':0},'expectedCharacterCount':offset,'graphics':[],'markers':[],'paragraphs':[],'plainText':text,'recognizedFormat':'libron-import-v1','runs':[],'warnings':[],'richTextRTF':rtf(text)}
            o.put(db,'section/'+str(ordinal),{'text':text,'content':content,'graphics':[],'inlineLinks':[],'interlinearLines':[]})
        o.put(db,'header',header);db.commit();assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok';db.close();raw.close()
        m['id']=identity;m['metadata']['title']=base['title']+' — anotaciones Strong'
        m['metadata']['evidence']=[e for e in base['libron'].get('evidence',[]) if e['field']=='editionAlias']
        m['metadata']['evidence'].append({'field':'editionAlias','value':o.path(base['location']).stem,'source':'same Bible edition','status':'verified'})
        data=(target/'normalized/reader.sqlite').read_bytes();m['normalizedContent']={'path':'normalized/reader.sqlite','sha256':o.digest(data),'byteCount':len(data)}
        o.write_json(target/'manifest.json',m);o.write_json(target/'annotation-source.json',{'package':str(original),'sourcePayloadSHA256':m['payload']['sha256']})
    else:m=o.json.loads((target/'manifest.json').read_text())
    evidence['value']=str(target)
    base_manifest=o.path(base['packageLocation'])/'manifest.json';base_m=o.json.loads(base_manifest.read_text());base_m['metadata']=base['libron'];o.write_json(base_manifest,base_m)
    variant={'id':identity,'libron':m['metadata'],'title':m['metadata']['title'],'packageLocation':target.as_uri(),'location':(target/m['payload']['path']).as_uri(),'byteCount':m['payload']['byteCount'],'format':m['sourceFormat'],'support':m['support'],'provenance':'libronixMetadata','languages':m['metadata'].get('languages',[]),'isHelp':m['isHelp'],'warnings':[]}
    if m.get('legacyIdentifier'):variant['legacyIdentifier']=m['legacyIdentifier']
    if m.get('index'):variant['indexLocation']=(target/m['index']['path']).as_uri()
    if m['metadata'].get('authors'):variant['author']='; '.join(m['metadata']['authors'])
    if not any(r['id']==identity for r in resources):resources.append(variant)
    if identity not in hidden:
        hidden.add(identity);visibility['hidden'].append({k:variant[k] for k in ['id','title','format','legacyIdentifier'] if k in variant})
    receipt.append({'title':base['title'],'annotationPackage':str(target),'originalPreserved':str(original),'morphologyHidden':True})
o.write_json(library/'catalog.json',catalog);o.write_json(visibility_path,visibility);o.write_json(output/'strong-presentation-receipt.json',receipt)
print(o.json.dumps(receipt,ensure_ascii=False))
