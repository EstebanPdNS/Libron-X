#!/usr/bin/env python3
"""Reproducibly convert twelve attributed monolingual data sets to .libron.

Run explicitly after downloading the source files listed below into sources/.
Application builds never download data. Exact source bytes, notices, data
licenses and this conversion script accompany the generated dictionaries.
"""
import collections
import gzip
import hashlib
import json
import pathlib
import shutil
import sqlite3
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'Resources' / 'BundledDictionaries'
SOURCE = ROOT / 'sources'
PACKAGES = ROOT / 'Packages'
RECORDS = []

def text(element):
    return ' '.join(''.join(element.itertext()).split()) if element is not None else ''

def key(word):
    return unicodedata.normalize('NFC', word.replace('’', "'").strip().casefold())

def sha(data): return hashlib.sha256(data).hexdigest()

def emit(slug, title, language, origin, license_name, license_url, source_url, entries,
         source_files, notice_files, authors, subtype='Diccionario general', year=None, edition=None):
    grouped = {}
    for word, definition in entries:
        if not word.strip() or not definition.strip(): continue
        k = key(word)
        if k not in grouped: grouped[k] = [word, []]
        if definition not in grouped[k][1]: grouped[k][1].append(definition)
    assert 0 < len(grouped) <= 2_000_000, (slug,len(grouped))
    package = PACKAGES / (slug+'.libron'); content = package/'content'
    content.mkdir(parents=True,exist_ok=True)
    database = content/'dictionary.sqlite3'
    if database.exists(): database.unlink()  # Owned regenerable output only.
    db=sqlite3.connect(database)
    db.executescript('PRAGMA user_version=1; CREATE TABLE entries(ordinal INTEGER PRIMARY KEY,headword TEXT NOT NULL,body TEXT NOT NULL); CREATE TABLE lookup(key TEXT NOT NULL,ordinal INTEGER NOT NULL,PRIMARY KEY(key,ordinal)) WITHOUT ROWID;')
    for ordinal,(k,(word,definitions)) in enumerate(sorted(grouped.items())):
        body=word+'\n\n'+'\n\n'.join(definitions)
        db.execute('INSERT INTO entries VALUES(?,?,?)',(ordinal,word,body))
        db.execute('INSERT INTO lookup VALUES(?,?)',(k,ordinal))
    db.commit(); assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'; db.close()
    sources=[]
    for filename in source_files:
        path=SOURCE/filename; raw=path.read_bytes()
        destination=package/(filename if filename.endswith(('.gz','.zip')) else filename+'.gz')
        destination.write_bytes(raw if destination.name==filename else gzip.compress(raw,mtime=0))
        sources.append(dict(file=filename,sha256=sha(raw)))
    for filename in notice_files: shutil.copy2(SOURCE/filename,package/filename)
    shutil.copy2(__file__,package/'convert-dictionaries.py')
    attribution=f'''{title}\nAuthors / attribution parties: {', '.join(authors)}\nSource: {source_url}\nLicense: {license_name}\n{license_url}\n\nChanges by Libron-X: source data projected into plain Unicode entries,\nhomographs grouped and indexed in a read-only SQLite dictionary. No definitions\nwere translated. The adapted dictionary data retain the source data license.\nOriginal sources, license notices and conversion code accompany this package.\nNo endorsement by the original authors is implied.\n'''
    (package/'ATTRIBUTION.txt').write_text(attribution)
    payload=database.read_bytes()
    m=dict(title=title,authors=authors,contributors=[],resourceType='Diccionario o enciclopedia',
        category='Diccionarios y enciclopedias',subcategories=[subtype],tags=[origin,license_name,'offline'],
        languages=[language],origin=origin,publisher=origin,collection='Libron-X · Diccionarios libres',
        originalTitle=title,originalInformation=attribution,evidence=[
            dict(field='source',value=source_url,source=source_url,status='verified'),
            dict(field='license',value=license_name+' · '+license_url,source=source_url,status='verified')],
        pendingFields=[] if year else ['year'])
    if year:m['year']=year
    if edition:m['edition']=edition
    manifest=dict(format='org.libron.resource',schemaVersion=1,id='org.libronx.bundled.'+slug,
        metadata=m,originalName=source_files[0],sourceFormat='libronDictionary',isHelp=False,support='metadataOnly',
        payload=dict(path='content/dictionary.sqlite3',sha256=sha(payload),byteCount=len(payload)))
    (package/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    record=dict(id=manifest['id'],package=package.name,title=title,language=language,entries=len(grouped),
        source=source_url,sources=sources,payloadSHA256=sha(payload),license=license_name,licenseURL=license_url,subtype=subtype)
    RECORDS.append(record); print(slug,len(grouped),flush=True)

def wiktionary(code,title):
    filename=code+'-extract.jsonl.gz';language='en' if code=='simple' else code
    data=[]
    with gzip.open(SOURCE/filename,'rt') as stream:
        for line in stream:
            entry=json.loads(line)
            if entry.get('lang_code')!=language:continue
            word=entry.get('word','');blocks=[]
            if entry.get('pos'):blocks.append(entry['pos'])
            for sense in entry.get('senses',[]):
                for gloss in sense.get('glosses',[]):blocks.append('• '+gloss)
                for example in sense.get('examples',[]):
                    if example.get('text'):blocks.append('  '+example['text'])
            if not blocks:continue
            page=f'https://{code}.wiktionary.org/wiki/'+urllib.parse.quote(word.replace(' ','_'),safe='')
            blocks.append('\n'+page)
            data.append((word,'\n'.join(blocks)))
    emit(code+'-wiktionary',title,language,'Wiktionary / Kaikki.org','CC BY-SA 4.0',
        'https://creativecommons.org/licenses/by-sa/4.0/',
        'https://kaikki.org/dictionary/rawdata.html',data,[filename],['CC-BY-SA-4.0.txt'],
        ['Wiktionary contributors','Tatu Ylonen / Wiktextract / Kaikki.org'])

def wordnet(code,language,title,license_name,license_url,notices,origin):
    filename='wn-data-'+code+'.tab';synsets=collections.defaultdict(lambda:collections.defaultdict(list))
    for line in (SOURCE/filename).read_text().splitlines():
        if not line or line.startswith('#'):continue
        parts=line.split('\t');kind=parts[1].split(':')[-1]
        if kind in ('lemma','def','exe'):
            synsets[parts[0]][kind].append(parts[-1])
    data=[];synonym_label={'es':'Sinónimos','it':'Sinonimi','pt':'Sinônimos'}[language]
    for values in synsets.values():
        lemmas=values['lemma'];defs=values['def'];examples=values['exe']
        for word in lemmas:
            others=[other for other in lemmas if other!=word]
            body=['• '+definition for definition in defs]
            if others:body.append(synonym_label+': '+', '.join(others))
            if examples:body+=['  '+example for example in examples]
            if body:data.append((word,'\n'.join(body)))
    emit(language+'-'+code+'-wordnet',title,language,origin,license_name,license_url,
        'https://github.com/omwn/omw-data/tree/main/wns/'+('mcr' if code=='spa' else code),
        data,[filename],notices,[origin,'Open Multilingual Wordnet'],
        subtype='Definiciones y sinónimos' if any(v['def'] for v in synsets.values()) else 'Diccionario de sinónimos')

def thesaurus(language,title,license_name,license_url):
    filename=language+'-thesaurus.dat';raw=(SOURCE/filename).read_bytes();encoding,body=raw.split(b'\n',1)
    lines=iter(body.decode(encoding.decode().strip()).splitlines());data=[]
    for line in lines:
        word,count=line.rsplit('|',1);senses=[next(lines).replace('|',', ') for _ in range(int(count))]
        data.append((word,'\n'.join(senses)))
    emit(language+'-thesaurus',title,language,'OpenThesaurus / LibreOffice',license_name,license_url,
        'https://github.com/LibreOffice/dictionaries/tree/master/'+('es' if language=='es' else 'it_IT'),
        data,[filename],[language+'-thesaurus-LICENSE.txt']+(['LGPL-2.1.txt'] if language=='es' else []),
        ['Marcelo Garrone'] if language=='es' else ['Davide Prina','Daniel Naber','Marco Barisione'],subtype='Diccionario de sinónimos')

def dicaberto():
    data=[];filename='dicaberto-xmls.zip'
    with zipfile.ZipFile(SOURCE/filename) as archive:
        for name in sorted(archive.namelist()):
            if not name.endswith('.xml'):continue
            for entry in ET.fromstring(archive.read(name)).findall('.//entry'):
                word=text(entry.find('form/orth'));blocks=[]
                for sense in entry.findall('sense'):
                    for child in sense:
                        value=text(child)
                        if value:blocks.append(value)
                if entry.find('etym') is not None:blocks.append(text(entry.find('etym')))
                if blocks:data.append((word,'\n'.join(blocks)))
    emit('pt-dicaberto','Dicionário Aberto — Cândido de Figueiredo', 'pt','Dicionário Aberto',
        'CC BY-SA 2.5 PT','https://creativecommons.org/licenses/by-sa/2.5/pt/',
        'https://github.com/ambs/Dicionario-Aberto/tree/master/Resources',data,[filename],['CC-BY-SA-2.5-PT.html'],
        ['Cândido de Figueiredo','Dicionário Aberto / Alberto Simões','Distributed Proofreaders'],year='1913')

def biblical(name,title,author,year):
    data=[];filename=name+'.xml';root=ET.parse(SOURCE/filename)
    for glossary in root.findall('.//glossary'):
        word=None
        for child in glossary:
            if child.tag=='term':word=text(child)
            elif child.tag=='def' and word:
                paragraphs=child.findall('p')
                definition='\n\n'.join(text(p) for p in paragraphs) if paragraphs else text(child)
                if definition:data.append((word,definition))
    emit('en-'+name,title,'en','CCEL / NEUU','CC BY 4.0',
        'https://creativecommons.org/licenses/by/4.0/',
        'https://github.com/neuu-org/bible-dictionary-dataset',data,[filename],['NEUU-LICENSE.txt','CC-BY-4.0.txt'],
        [author,'Christian Classics Ethereal Library','NEUU (electronic dataset)'],subtype='Diccionario bíblico',year=year)

def main():
    if PACKAGES.exists():
        candidates=ROOT/'candidates';candidates.mkdir(exist_ok=True)
        for package in PACKAGES.glob('*.libron'):
            if package.name.split('.')[0] in ['es-en','es-pt','es-it','es-fr','es-de','en-es','en-pt','en-it','en-fr','en-de','pt-es','pt-en','pt-it','pt-fr','pt-de','it-es','it-en','it-pt','it-fr','it-de']:
                shutil.move(str(package),candidates/package.name)
    wiktionary('es','Wikcionario — Español')
    wordnet('spa','es','WordNet español — MCR','CC BY 3.0','https://creativecommons.org/licenses/by/3.0/', ['MCR-LICENSE.txt','CC-BY-3.0.txt'],'Multilingual Central Repository')
    thesaurus('es','OpenThesaurus — Sinónimos en español','LGPL-2.1','https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html')
    wiktionary('simple','Simple English Wiktionary')
    biblical('easton',"Easton's Bible Dictionary — 1897",'Matthew George Easton','1897')
    biblical('smith',"Smith's Bible Dictionary — 1863",'William Smith','1863')
    wiktionary('pt','Wikcionário — Português')
    dicaberto()
    wordnet('por','pt','OpenWordnet-PT — Sinônimos','CC BY-SA 3.0','https://creativecommons.org/licenses/by-sa/3.0/', ['OWNPT-LICENSE.txt'],'OpenWordnet-PT')
    wiktionary('it','Wikizionario — Italiano')
    wordnet('ita','it','MultiWordNet — Italiano','CC BY 3.0','https://creativecommons.org/licenses/by/3.0/', ['MWN-LICENSE.txt','CC-BY-3.0.txt'],'MultiWordNet / FBK')
    thesaurus('it','Thesaurus italiano','GPL-3.0','https://www.gnu.org/licenses/gpl-3.0.html')
    assert len(RECORDS)==12
    (ROOT/'catalog.json').write_text(json.dumps(dict(schemaVersion=1,dictionaries=RECORDS),ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(dictionaries=len(RECORDS),entries=sum(r['entries'] for r in RECORDS),languages=dict(collections.Counter(r['language'] for r in RECORDS)))),flush=True)

if __name__=='__main__':main()
