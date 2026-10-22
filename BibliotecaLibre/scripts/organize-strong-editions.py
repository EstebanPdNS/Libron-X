#!/usr/bin/env python3
"""Associate Strong annotations with their Bible edition, retaining originals."""
import copy
import importlib.util
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import html

spec=importlib.util.spec_from_file_location('organization',Path(__file__).with_name('organize-library.py'))
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o)


def without_strong(text):
    text=re.sub(r'<(?:num|tvm)\b[^>]*>.*?</(?:num|tvm)>','',text,flags=re.I|re.S)
    text=re.sub(r'(?<![A-Za-z])[HG]\d+(?!\d)','',text)
    text=html.unescape(re.sub(r'<[^>]+>','',text))
    text=re.sub(r'\[\s*\]','',text)
    return re.sub(r'[ \t]+',' ',text).strip()


def plain_companion(source,library,title):
    original=o.path(source['packageLocation']);manifest=o.json.loads((original/'manifest.json').read_text())
    identifier='/libron/strong-editions/'+manifest['payload']['sha256']
    target=library/(title+' — '+manifest['payload']['sha256'][:16]+'-plain.libron')
    if target.exists():return o.json.loads((target/'catalog-entry.json').read_text())
    shutil.copytree(original,target)
    resource=copy.deepcopy(source);resource.update(id=identifier,title=title,packageLocation=target.as_uri(),location=(target/manifest['payload']['path']).as_uri())
    db=sqlite3.connect(target/'normalized/reader.sqlite');header=o.get(db,'header');header['resourceID']=identifier
    raw=sqlite3.connect(o.path(source['location']));groups={}
    for book,chapter,verse,text in raw.execute('SELECT Book,Chapter,Verse,Scripture FROM Bible ORDER BY Book,Chapter,Verse'):
        groups.setdefault((book,chapter),[]).append((verse,without_strong(text)))
    assert len(groups)==header['sectionCount'],'Strong chapter layout changed'
    book_keys={row[0]:row[1] for row in db.execute('SELECT ordinal,book FROM bible_v1')}
    db.execute('DELETE FROM bible_v1')
    for ordinal,((book,chapter),verses) in enumerate(groups.items()):
        old=o.get(db,'section/'+str(ordinal));parts=[];anchors=[];offset=0
        for verse,text in verses:
            code=o.BOOKS[book-1] if book in range(1,67) else f'Book {book}'
            reference=f'{code} {chapter}:{verse}'
            anchors.append({'characterOffset':offset,'dataTypeCode':0,'decodedOffset':0,'flags':0,'reference':reference})
            db.execute('INSERT INTO bible_v1 VALUES(?,?,?,?,?,?)',(book_keys.get(ordinal,code.lower()),chapter,verse,ordinal,offset,reference))
            line=f'{verse} {text}\n';parts.append(line);offset+=len(line.encode('utf-16-le'))//2
        text=''.join(parts)
        content={'anchors':anchors,'descriptor':{'ordinal':ordinal,'headerOffset':0,'payloadOffset':0,'storedLength':0,'decodedLength':offset,'mode':0},'expectedCharacterCount':offset,'graphics':[],'markers':[],'paragraphs':[],'plainText':text,'recognizedFormat':'libron-import-v1','runs':[],'warnings':[]}
        section={'text':text,'content':content,'graphics':old.get('graphics',[]),'inlineLinks':[],'interlinearLines':[]}
        o.put(db,'section/'+str(ordinal),section)
    o.put(db,'header',header);db.commit();assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok';db.close();raw.close()
    manifest['id']=identifier;manifest['metadata']['title']=title;resource['libron']=copy.deepcopy(manifest['metadata'])
    data=(target/'normalized/reader.sqlite').read_bytes();manifest['normalizedContent']={'path':'normalized/reader.sqlite','byteCount':len(data),'sha256':o.digest(data)}
    o.write_json(target/'manifest.json',manifest);o.write_json(target/'catalog-entry.json',resource)
    return resource


def main():
    library=Path(sys.argv[1]).resolve();output=Path(sys.argv[2]);output.mkdir(parents=True,exist_ok=True)
    catalog=o.json.loads((library/'catalog.json').read_text());resources=catalog['resources']
    hidden_path=Path.home()/'Library/Application Support/org.libronx.mac.rebuild/hidden-resources.json'
    visibility=o.json.loads(hidden_path.read_text());hidden={r['id'] for r in visibility['hidden']}
    before=output/'before-strong-catalog.json'
    if not before.exists():o.write_json(before,catalog);o.write_json(output/'before-strong-visibility.json',visibility)
    def filename(resource):return o.path(resource['location']).name
    by_name={filename(r):r for r in resources if not r['id'].startswith('/libron/')}
    associations=[('spanishrv+.bbli','spanishrv.bbli','Reina-Valera 1909'),
        ('RO1960+ Strong.bbli','rvr60.lbxlls','Reina-Valera 1960'),
        ('ara_ra_com_strongs.bbli',None,'Almeida Revista e Atualizada, 1993'),
        ('BHS+.bbli',None,'Biblia Hebraica Stuttgartensia (Crosswalk)'),
        ('gnt-tr+.bbli',None,'Textus Receptus Greek New Testament')]
    receipt=[]
    def hide(resource):
        if resource['id'] not in hidden:
            hidden.add(resource['id']);visibility['hidden'].append({k:resource[k] for k in ['id','title','format','legacyIdentifier'] if k in resource})
    for strong_name,base_name,title in associations:
        strong=by_name[strong_name]
        if base_name:base=by_name[base_name]
        else:
            base=plain_companion(strong,library,title)
            if not any(r['id']==base['id'] for r in resources):resources.append(base)
            else:base=next(r for r in resources if r['id']==base['id'])
        metadata=copy.deepcopy(base['libron']);metadata['title']=title
        metadata['evidence']=[e for e in metadata.get('evidence',[]) if e['field'] not in ['strongVariantPackage','editionAlias']]
        metadata['evidence'].append({'field':'strongVariantPackage','value':str(o.path(strong['packageLocation'])),'source':'edition-organization','status':'verified'})
        folded_aliases=[]
        if title=='Reina-Valera 1960':
            folded_aliases=[r for r in resources if r['id']!=base['id'] and r.get('libron',{}).get('resourceType')=='Biblia' and '1960' in r['title'] and ('reina' in o.folded(r['title']) or filename(r).upper()=='RVR60.LSF')]
        elif title=='Reina-Valera 1909':
            folded_aliases=[r for r in resources if r['id']!=base['id'] and r.get('libron',{}).get('resourceType')=='Biblia' and '1909' in r['title'] and 'reina' in o.folded(r['title'])]
        for alias in folded_aliases:
            metadata['evidence'].append({'field':'editionAlias','value':o.path(alias['location']).stem,'source':alias['id'],'status':'verified'});hide(alias)
        base['libron']=metadata;base['title']=title
        mpath=o.path(base['packageLocation'])/'manifest.json';m=o.json.loads(mpath.read_text());m['metadata']=metadata;o.write_json(mpath,m)
        hide(strong);receipt.append({'title':title,'baseID':base['id'],'strongID':strong['id'],'foldedPlainEditions':len(folded_aliases)})
    # The Spanish Henry imports contain the same concise work. Prefer the
    # native chapter edition; keep the e-Sword import and all its unique text.
    henry=next(r for r in resources if filename(r).lower()=='mhenryesp.lbxlls')
    alternate=next(r for r in resources if r['title']=='Comentario de la Biblia de Matthew Henry')
    metadata=copy.deepcopy(henry['libron']);metadata['title']='Comentario bíblico de Matthew Henry (conciso)'
    metadata['evidence'].append({'field':'alternateEditionPackage','value':str(o.path(alternate['packageLocation'])),'source':'8-word-shingle-audit: 99.889% of native chapter edition shared','status':'verified'})
    henry['libron']=metadata;henry['title']=metadata['title'];mpath=o.path(henry['packageLocation'])/'manifest.json';m=o.json.loads(mpath.read_text());m['metadata']=metadata;o.write_json(mpath,m);hide(alternate)
    o.write_json(library/'catalog.json',catalog);o.write_json(hidden_path,visibility);o.write_json(output/'strong-receipt.json',{'associations':receipt,'henry':'Both Spanish imports are the concise work; chapter edition retained, alternate preserved hidden. Portuguese and English editions remain separate.','originalPackagesPreserved':True})
    print(o.json.dumps(receipt,ensure_ascii=False))


if __name__=='__main__':main()
