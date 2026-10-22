#!/usr/bin/env python3
"""Combine declared commentary volumes without removing their source packages.

Writes a new native package, a portable EPUB fallback and a source-address map.
Only explicit contents headings (not citations in prose) establish coverage.
"""
import argparse
import copy
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import sqlite3
import unicodedata
from urllib.parse import unquote, urlparse
import zipfile
import zlib


BOOKS = 'Ge Ex Le Nu De Jos Jdg Ru 1Sa 2Sa 1Ki 2Ki 1Ch 2Ch Ezr Ne Es Job Ps Pr Ec So Isa Jer La Eze Da Ho Joe Am Ob Jon Mic Na Hab Zep Hag Zec Mal Mt Mr Lu Joh Ac Ro 1Co 2Co Ga Eph Php Col 1Th 2Th 1Ti 2Ti Tit Phm Heb Jas 1Pe 2Pe 1Jo 2Jo 3Jo Jude Re'.split()
NAMES = ['Génesis', 'Éxodo', 'Levítico', 'Números', 'Deuteronomio', 'Josué', 'Jueces', 'Rut', '1 Samuel', '2 Samuel', '1 Reyes', '2 Reyes', '1 Crónicas', '2 Crónicas', 'Esdras', 'Nehemías', 'Ester', 'Job', 'Salmos', 'Proverbios', 'Eclesiastés', 'Cantares', 'Isaías', 'Jeremías', 'Lamentaciones', 'Ezequiel', 'Daniel', 'Oseas', 'Joel', 'Amós', 'Abdías', 'Jonás', 'Miqueas', 'Nahúm', 'Habacuc', 'Sofonías', 'Hageo', 'Zacarías', 'Malaquías', 'Mateo', 'Marcos', 'Lucas', 'Juan', 'Hechos', 'Romanos', '1 Corintios', '2 Corintios', 'Gálatas', 'Efesios', 'Filipenses', 'Colosenses', '1 Tesalonicenses', '2 Tesalonicenses', '1 Timoteo', '2 Timoteo', 'Tito', 'Filemón', 'Hebreos', 'Santiago', '1 Pedro', '2 Pedro', '1 Juan', '2 Juan', '3 Juan', 'Judas', 'Apocalipsis']


def folded(text):
    return ''.join(c for c in unicodedata.normalize('NFD', text.lower()) if not unicodedata.combining(c))


def path(url):
    return Path(unquote(urlparse(url).path))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def get(db, key):
    row = db.execute('SELECT body FROM values_v1 WHERE key=?', (key,)).fetchone()
    return json.loads(zlib.decompress(row[0])) if row else None


def put(db, key, value):
    data = encoded(value)
    db.execute('INSERT OR REPLACE INTO values_v1 VALUES(?,?,?,?)', (key, zlib.compress(data), len(data), digest(data)))


def write_json(file, value):
    temporary = file.with_suffix(file.suffix + '.next')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(file)


def book_heading(title):
    original_text = folded(title).strip(' .:()')
    declared = {'las epistolas pastorales del apostol pablo a timoteo y tito':'1Ti', 'el apocalipsis o revelacion de juan, el teologo':'Re', 'epistola general de judas':'Jude','los hechos de los apostoles':'Ac','el cantar de los cantares de salomon':'So'}
    if original_text in declared: return declared[original_text]
    text = original_text
    text = re.sub(r'^(?:evangelio (?:segun )?|san |libro (?:de |del )?)', '', text)
    aliases = {folded(name): code for code, name in zip(BOOKS, NAMES)}
    aliases.update({'salmo': 'Ps', 'cantar de los cantares': 'So', 'cantares de salomon': 'So', 'cantar de cantares': 'So', 'carta a los romanos': 'Ro'})
    aliases.update({'ecclesiastes; o, el predicador':'Ec','las lamentaciones de jeremias':'La','cantar de los cantaresde salomon':'So','cantar de los cantares de salomon':'So'})
    if text in aliases: return aliases[text]
    # Expanded source book headings, e.g. EL PRIMER LIBRO DE MOISES,
    # LLAMADO GENESIS or LA SEGUNDA EPISTOLA ... A LOS CORINTIOS.
    if re.match(r'^(?:el |la |las |los |libro |primer|segund|tercer)', original_text):
        ordinal = re.search(r'\b(primer[oa]?|segund[oa]|tercer[oa]?)\b', text)
        number = {'primer':1,'primero':1,'primera':1,'segundo':2,'segunda':2,'tercer':3,'tercero':3,'tercera':3}.get(ordinal[1],0) if ordinal else 0
        for code,name in zip(BOOKS,NAMES):
            plain = folded(re.sub(r'^\d ', '', name))
            if re.search(r'\b'+re.escape(plain)+r'$', text):
                if code[0].isdigit():
                    if number == int(code[0]): return code
                elif not (number and plain in ['juan','pedro','timoteo','corintios','tesalonicenses']): return code
        if text.endswith('tesalonicences') and number: return str(number)+'Th'
    return None


def heading_coverage(header, resource, verse_counts, db=None):
    title = resource['title']
    suffix = title.split(':', 1)[-1].strip() if ':' in title else ''
    current_book = book_heading(re.sub(r'\s+[IVX]+$', '', suffix))
    entries = header['entries']
    result = []
    current_range = None
    current_chapter = None
    outline_ranges = {}
    def heading_key(text): return re.sub(r'\s+', ' ', folded(text)).strip(' .\t')
    for i, entry in enumerate(entries):
        text = entry['title']
        if db is not None and folded(text) == 'bosquejo general':
            outline = get(db, 'section/'+str(entry['ordinal']))
            outline_ranges = {}
            for line in (outline or {}).get('text','').splitlines():
                match = re.match(r'^(.*?)\s+(\d{1,3}:\d{1,3}(?:[-–—](?:\d{1,3}:)?\d{1,3})?)\s*$',line)
                if match: outline_ranges[heading_key(match[1])] = match[2]
        if heading_key(text) in outline_ranges: text += ' ('+outline_ranges[heading_key(text)]+')'
        own_book = book_heading(text)
        if own_book:
            current_book = own_book; current_range = None; current_chapter = None; outline_ranges = {}
        if not current_book:
            continue
        ranges = list(re.finditer(r'(?<!\d)(\d{1,3}):(\d{1,3})[abcd]?(?:\s*[-–—]\s*(?:(\d{1,3}):)?(\d{1,3})[abcd]?)?', text))
        chapter_match = re.fullmatch(r'\s*(?:capitulos?(?:\s*\([^)]*\))?|salmo)\s+(\d{1,3}|[ivxlcdm]+)(?:\s*[-–—]\s*(\d{1,3}|[ivxlcdm]+))?\s*', folded(text))
        psalm = re.match(r'^salmos?\s+(\d{1,3})(?:\s*(?:[-–—]|y)\s*(\d{1,3}))?(?:\s*[:.]|\s|$)', folded(text))
        if psalm:
            current_book = 'Ps'; chapter_match = psalm
        if current_book and not current_chapter and own_book in ['Ob','Phm','2Jo','3Jo','Jude']:
            current_chapter = 1; current_range = (1,1,1,verse_counts.get((current_book,1),0))
        verse_only = re.search(r'\bvv?\.\s*(\d{1,3})(?:\s*[-–—,]\s*(\d{1,3}))?',text)
        if ranges:
            match = ranges[-1]
            chapter, verse = int(match[1]), int(match[2])
            end_chapter = int(match[3]) if match[3] else chapter
            end_verse = int(match[4]) if match[4] else verse
        elif chapter_match:
            number = chapter_match[1]
            if number.isdigit(): chapter = int(number)
            else:
                roman = {'i':1,'v':5,'x':10,'l':50,'c':100,'d':500,'m':1000}; chapter=0; previous=0
                for letter in reversed(number):
                    value=roman[letter];chapter += -value if value<previous else value;previous=max(previous,value)
            end_chapter = int(chapter_match[2]) if chapter_match.lastindex and chapter_match.lastindex>=2 and chapter_match[2] and chapter_match[2].isdigit() else chapter
            verse = 1
            end_verse = verse_counts.get((current_book, end_chapter), 0)
        elif verse_only and current_chapter:
            chapter = end_chapter = current_chapter; verse = int(verse_only[1]); end_verse = int(verse_only[2] or verse_only[1])
        elif current_range and not any(x in folded(text) for x in ['bibliografia','introduccion','prefacio']):
            chapter,verse,end_chapter,end_verse = current_range
        else:
            continue
        if not (verse > 0 and end_verse > 0 and (chapter, verse) <= (end_chapter, end_verse)):
            continue
        if verse > verse_counts.get((current_book, chapter), 0) or end_verse > verse_counts.get((current_book, end_chapter), 0):
            continue
        current_range = (chapter,verse,end_chapter,end_verse)
        if chapter == end_chapter: current_chapter = chapter
        # Continuation sections, sidebars and illustrations belong to this
        # explicitly printed heading until the next contents heading.
        stop = entries[i+1]['ordinal'] if i+1 < len(entries) else header['sectionCount']
        stop = max(entry['ordinal'] + 1, stop)
        for ordinal in range(entry['ordinal'], stop):
            result.append({'start': f'{current_book} {chapter}:{verse}', 'end': f'{current_book} {end_chapter}:{end_verse}', 'ordinal': ordinal, 'offset': 0})
    return result


def esword_coverage(resource, verse_counts):
    if resource['format'] != 'eSwordSQLite':
        return []
    db = sqlite3.connect(path(resource['location']))
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'VerseCommentary' not in tables:
        db.close(); return []
    books = list(db.execute('SELECT Book FROM BookCommentary ORDER BY Book,rowid'))
    chapters = list(db.execute('SELECT Book,Chapter FROM ChapterCommentary ORDER BY Book,Chapter,rowid'))
    rows = list(db.execute('SELECT Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd FROM VerseCommentary ORDER BY Book,ChapterBegin,VerseBegin,rowid'))
    result = []
    for i, (b, c, v, ec, ev) in enumerate(rows):
        if b not in range(1, 67) or (c, v) > (ec, ev) or min(c, v, ec, ev) <= 0:
            continue
        result.append({'start': f'{BOOKS[b-1]} {c}:{v}', 'end': f'{BOOKS[b-1]} {ec}:{ev}', 'ordinal': len(books)+len(chapters)+i, 'offset': 0})
    for i, (b, c) in enumerate(chapters):
        if b in range(1, 67) and (BOOKS[b-1], c) in verse_counts:
            result.append({'start': f'{BOOKS[b-1]} {c}:1', 'end': f'{BOOKS[b-1]} {c}:{verse_counts[BOOKS[b-1],c]}', 'ordinal': len(books)+i, 'offset': 0})
    db.close()
    return result


def index_for(resource, db, header, verse_counts):
    saved = get(db, 'commentary-index')
    return saved if saved is not None else (esword_coverage(resource, verse_counts) or heading_coverage(header, resource, verse_counts, db))


def make_collection(resources, title, library, verse_counts):
    source_manifest = {'title': title, 'volumes': [{'id': r['id'], 'package': r['packageLocation'], 'sha256': json.loads((path(r['packageLocation'])/'manifest.json').read_text())['payload']['sha256']} for r in resources]}
    identity = digest(encoded(source_manifest))
    identifier = '/libron/collections/' + identity
    target = library / (title + ' — ' + identity[:16] + '.libron')
    if target.exists():
        return json.loads((target/'catalog-entry.json').read_text())
    stage = library / ('.collection-' + identity[:16])
    stage.mkdir(); (stage/'content').mkdir(); (stage/'normalized').mkdir()
    first = sqlite3.connect(path(resources[0]['packageLocation'])/'normalized/reader.sqlite')
    db = sqlite3.connect(stage/'normalized/reader.sqlite')
    for sql, in first.execute("SELECT sql FROM sqlite_master WHERE type='table'"):
        db.execute(sql)
    db.execute('PRAGMA user_version=1'); first.close()
    entries, coverage, address_map, counts = [], [], [], []
    ordinal_base = 0
    fallback = stage/'content/collection.epub'
    spine = []
    with zipfile.ZipFile(fallback, 'w', zipfile.ZIP_DEFLATED) as epub:
        epub.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        epub.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        for resource in resources:
            source = sqlite3.connect(path(resource['packageLocation'])/'normalized/reader.sqlite')
            header = get(source, 'header')
            entries.append({'id': -len(address_map)-1, 'ordinal': ordinal_base + (header['entries'][0]['ordinal'] if header['entries'] else 0), 'title': resource['title'], 'depth': 0})
            entries.extend(dict(entry, id=entry['ordinal']+ordinal_base, ordinal=entry['ordinal']+ordinal_base, depth=entry.get('depth',0)+1) for entry in header['entries'])
            source_index = index_for(resource, source, header, verse_counts)
            coverage.extend(dict(entry, ordinal=entry['ordinal']+ordinal_base) for entry in source_index)
            for key, body, size, sha in source.execute('SELECT key,body,size,sha256 FROM values_v1'):
                if key.startswith('section/'):
                    old = int(key.split('/')[1]); section = json.loads(zlib.decompress(body))
                    # Preserve source structures and byte addresses. Rebase
                    # article targets; character offsets remain unchanged.
                    for link in section.get('inlineLinks', []):
                        if 'article' in link.get('target', {}):
                            link['target']['article']['_0'] += ordinal_base
                    put(db, 'section/'+str(old+ordinal_base), section)
                    name = f'section-{old+ordinal_base}.xhtml'; spine.append(name)
                    epub.writestr(name, '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>'+html.escape(resource['title'])+'</title></head><body><p>'+html.escape(section['text']).replace('\n','</p><p>')+'</p></body></html>')
                elif key.startswith('typography/'):
                    db.execute('INSERT OR IGNORE INTO values_v1 VALUES(?,?,?,?)', (key,body,size,sha))
            for book, chapter, verse, ordinal, offset, ref in source.execute('SELECT * FROM bible_v1'):
                db.execute('INSERT OR IGNORE INTO bible_v1 VALUES(?,?,?,?,?,?)', (book,chapter,verse,ordinal+ordinal_base,offset,ref))
            address_map.append({'firstOrdinal':ordinal_base, 'count':header['sectionCount'], 'resource':resource})
            counts.append({'title':resource['title'],'sections':header['sectionCount'],'coverageRanges':len(source_index)})
            ordinal_base += header['sectionCount']; source.close()
        manifest = ''.join(f'<item id="s{i}" href="{name}" media-type="application/xhtml+xml"/>' for i,name in enumerate(spine))
        refs = ''.join(f'<itemref idref="s{i}"/>' for i in range(len(spine)))
        epub.writestr('content.opf', f'<?xml version="1.0"?><package version="2.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">{identity}</dc:identifier><dc:title>{html.escape(title)}</dc:title><dc:language>es</dc:language></metadata><manifest>{manifest}</manifest><spine>{refs}</spine></package>')
    source_hash = digest(fallback.read_bytes())
    put(db, 'header', {'schemaVersion':1,'resourceID':identifier,'sourceSHA256':source_hash,'sectionCount':ordinal_base,'profile':'structured-text','entries':entries,'chapters':[]})
    put(db, 'commentary-index', coverage); put(db, 'source-volumes', address_map)
    db.commit(); assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'; db.close()
    metadata = copy.deepcopy(resources[0]['libron']); metadata['title']=title
    metadata['authors']=list(dict.fromkeys(a for r in resources for a in r.get('libron',{}).get('authors',[])))
    metadata['collection']=title; metadata['edition']='Colección de los tomos disponibles'
    metadata['biblicalCoverage']=f'{len(resources)} tomos disponibles; {len(coverage)} intervalos de comentario indexados'
    metadata['evidence'] = metadata.get('evidence',[]) + [{'field':'collectionMembers','value':json.dumps([r['id'] for r in resources]),'source':'source-volumes.json','status':'verified'}]
    def member(file, relative):
        data=file.read_bytes();return {'path':relative,'byteCount':len(data),'sha256':digest(data)}
    m={'format':'org.libron.resource','schemaVersion':1,'id':identifier,'metadata':metadata,'originalName':'collection.epub','sourceFormat':'epub','isHelp':False,'support':'metadataOnly','payload':member(fallback,'content/collection.epub'),'normalizedContent':member(stage/'normalized/reader.sqlite','normalized/reader.sqlite')}
    write_json(stage/'manifest.json',m);write_json(stage/'source-volumes.json',source_manifest);write_json(stage/'normalized/conversion.json',{'schemaVersion':1,'converterVersion':3,'navigationVersion':3,'resourceID':identifier,'sourceSHA256':source_hash,'state':'complete','profile':'structured-text','sections':ordinal_base,'checkedSections':ordinal_base,'warnings':[],'volumes':counts})
    result={'id':identifier,'libron':metadata,'packageLocation':target.as_uri(),'location':(target/'content/collection.epub').as_uri(),'title':title,'author':'; '.join(metadata['authors']),'languages':metadata.get('languages',['es']),'byteCount':m['payload']['byteCount'],'format':'epub','support':'metadataOnly','provenance':'libronixMetadata','isHelp':False,'warnings':[]}
    write_json(stage/'catalog-entry.json',result);stage.rename(target)
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('library',type=Path);parser.add_argument('--output',required=True,type=Path);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    args.library=args.library.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    catalog_path=args.library/'catalog.json'; catalog=json.loads(catalog_path.read_text());resources=catalog['resources']
    hidden_path=Path.home()/'Library/Application Support/org.libronx.mac.rebuild/hidden-resources.json'
    visibility=json.loads(hidden_path.read_text());hidden={r['id'] for r in visibility['hidden']}
    source=[r for r in resources if r['id'] not in hidden]
    groups=[('Comentario bíblico del Continente Nuevo',lambda r: folded(r['title']).startswith('comentario biblico del continente nuevo:')),
            ('Comentario bíblico Mundo Hispano',lambda r: folded(r['title']).startswith('comentario biblico mundo hispano tomo ')),
            ('Comentario exegético y explicativo de la Biblia',lambda r: folded(r['title']).startswith('comentario exegetico y explicativo de la biblia - tomo '))]
    plan=[{'title':title,'members':[r for r in source if predicate(r)]} for title,predicate in groups]
    write_json(args.output/'merge-plan.json',plan)
    if not args.apply:
        print(json.dumps([{ 'title':g['title'],'volumes':len(g['members'])} for g in plan],ensure_ascii=False));return
    for file in [catalog_path,hidden_path]:
        backup=args.output/('before-'+file.name)
        if not backup.exists(): shutil.copy2(file,backup)
    base=next(r for r in resources if Path(unquote(urlparse(r['location']).path)).name=='spanishrv.bbli')
    bible=sqlite3.connect(path(base['location']));verse_counts={(BOOKS[b-1],c):v for b,c,v in bible.execute('SELECT Book,Chapter,MAX(Verse) FROM Bible GROUP BY Book,Chapter') if b in range(1,67)};bible.close()
    receipt=[]
    for group in plan:
        members=group['members']
        if len(members)<2:continue
        def sequence(resource):
            volume=re.search(r'\btomo (\d+)',folded(resource['title']))
            if volume:return int(volume[1])
            suffix=resource['title'].split(':',1)[-1].strip(); book=book_heading(re.sub(r'\s+[IVX]+$','',suffix))
            if not book:
                for code,name in zip(BOOKS,NAMES):
                    if folded(suffix).startswith(folded(name)):book=code;break
            return (BOOKS.index(book) if book in BOOKS else 100,resource['title'])
        members.sort(key=sequence)
        merged=make_collection(members,group['title'],args.library,verse_counts)
        resources.append(merged)
        for r in members:
            visibility['hidden'].append({k:r[k] for k in ['id','title','format','legacyIdentifier'] if k in r})
        receipt.append({'title':group['title'],'volumes':len(members),'resourceID':merged['id']})
    # Supply explicit e-Sword ranges and verified contents headings to all
    # stand-alone commentaries, including previously imported single volumes.
    indexed=[]
    for r in resources:
        if r.get('libron',{}).get('resourceType')!='Comentario bíblico':continue
        native=path(r['packageLocation'])/'normalized/reader.sqlite'
        if not native.exists():continue
        db=sqlite3.connect(native)
        if get(db,'commentary-index') is not None: db.close();continue
        header=get(db,'header');index=index_for(r,db,header,verse_counts)
        if index:
            shutil.copy2(native,args.output/(digest(r['id'].encode())[:16]+'-reader-before.sqlite'))
            put(db,'commentary-index',index);db.commit();db.close()
            mpath=native.parent.parent/'manifest.json';m=json.loads(mpath.read_text());data=native.read_bytes();m['normalizedContent']={'path':'normalized/reader.sqlite','byteCount':len(data),'sha256':digest(data)};write_json(mpath,m)
            indexed.append({'title':r['title'],'ranges':len(index)})
        else:db.close()
    write_json(catalog_path,catalog);write_json(hidden_path,visibility)
    write_json(args.output/'merge-receipt.json',{'merged':receipt,'indexed':indexed,'originalPackagesPreserved':True})
    print(json.dumps({'merged':receipt,'indexedCommentaries':len(indexed)},ensure_ascii=False))


if __name__=='__main__':main()
