#!/usr/bin/env python3
"""Refresh explicit source-heading coverage without rewriting source sections."""
import importlib.util
from pathlib import Path
import sqlite3
import sys

spec=importlib.util.spec_from_file_location('organization',Path(__file__).with_name('organize-library.py'))
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o)
library=Path(sys.argv[1]).resolve();output=Path(sys.argv[2]);catalog=o.json.loads((library/'catalog.json').read_text())
resources=catalog['resources'];base=next(r for r in resources if o.path(r['location']).name=='spanishrv.bbli')
bible=sqlite3.connect(o.path(base['location']));counts={(o.BOOKS[b-1],c):v for b,c,v in bible.execute('SELECT Book,Chapter,MAX(Verse) FROM Bible GROUP BY Book,Chapter') if b in range(1,67)};bible.close()
receipt=[]
for resource in resources:
    if resource.get('libron',{}).get('resourceType')!='Comentario bíblico':continue
    native=o.path(resource['packageLocation'])/'normalized/reader.sqlite'
    if not native.exists():continue
    db=sqlite3.connect(native);members=o.get(db,'source-volumes')
    if members:
        index=[]
        for member in members:
            source=sqlite3.connect(o.path(member['resource']['packageLocation'])/'normalized/reader.sqlite');header=o.get(source,'header')
            part=o.esword_coverage(member['resource'],counts) or o.heading_coverage(header,member['resource'],counts,source)
            index.extend(dict(entry,ordinal=entry['ordinal']+member['firstOrdinal']) for entry in part);source.close()
    elif resource['format'] in ['libronixLLS','legacyLSF']:
        index=o.heading_coverage(o.get(db,'header'),resource,counts,db)
    else:db.close();continue
    if index:
        o.put(db,'commentary-index',index);db.commit();db.close()
        mpath=native.parent.parent/'manifest.json';manifest=o.json.loads(mpath.read_text());data=native.read_bytes();manifest['normalizedContent']={'path':'normalized/reader.sqlite','sha256':o.digest(data),'byteCount':len(data)};o.write_json(mpath,manifest)
        receipt.append({'title':resource['title'],'ranges':len(index),'books':sorted({entry['start'].split()[0] for entry in index})})
    else:db.close()
o.write_json(output/'reindex-receipt.json',receipt)
print(o.json.dumps([r for r in receipt if r['title'] in ['Comentario bíblico del Continente Nuevo','Comentario bíblico Mundo Hispano','Comentario exegético y explicativo de la Biblia','Comentario bíblico de Matthew Henry (conciso)']],ensure_ascii=False))
