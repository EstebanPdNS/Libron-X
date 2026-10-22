#!/usr/bin/env python3
"""Recompress v1 records losslessly in distribution copies; verify every decoded record."""
import argparse,hashlib,json,os,shutil,sqlite3,struct,tempfile,zlib
from pathlib import Path

def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while b:=f.read(1048576):h.update(b)
 return h.hexdigest()
def logical(db):
 h=hashlib.sha256()
 h.update(json.dumps(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall(),ensure_ascii=False).encode())
 records=0
 for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall():
  columns=db.execute('PRAGMA table_info("'+table+'")').fetchall();order=[c[1] for c in sorted(columns,key=lambda x:x[5]) if c[5]] or [c[1] for c in columns]
  query='SELECT * FROM "'+table+'" ORDER BY '+','.join('"'+c+'"' for c in order)
  for row in db.execute(query):
   if table=='values_v1':
    key,body,size,expected=row;data=zlib.decompress(body)
    if len(data)!=size or hashlib.sha256(data).hexdigest()!=expected:raise ValueError('Record integrity mismatch: '+key)
    row=(key,expected,size,expected);records+=1
   for value in row:
    b=value if isinstance(value,bytes) else json.dumps(value,ensure_ascii=False).encode();h.update(type(value).__name__.encode()+b'\0'+struct.pack('>Q',len(b))+b)
 return h.hexdigest(),records
def main():
 p=argparse.ArgumentParser();p.add_argument('--audit',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);results=[]
 for i,item in enumerate(json.loads((a.audit/'sqlite.json').read_text()),1):
  source=Path(item['path'])
  if source.name!='reader.sqlite' or source.parent.name!='normalized':continue
  destination=a.output/source.parent.parent.name/'normalized'/'reader.sqlite';existing=destination if destination.exists() else source
  original=sqlite3.connect(source.as_uri()+'?mode=ro',uri=True);before,records=logical(original);original.close();original_hash=sha(source)
  with tempfile.TemporaryDirectory(dir=a.output) as td:
   working=Path(td)/'reader.sqlite';shutil.copy2(existing,working);db=sqlite3.connect(working);db.execute('PRAGMA journal_mode=OFF');db.execute('PRAGMA synchronous=OFF');db.execute('BEGIN');changed=0;saved=0;updates=[]
   for key,body,size,expected in db.execute('SELECT key,body,size,sha256 FROM values_v1'):
    data=zlib.decompress(body)
    if len(data)!=size or hashlib.sha256(data).hexdigest()!=expected:raise ValueError('Invalid source record')
    replacement=zlib.compress(data,9)
    if len(replacement)<len(body):updates.append((replacement,key));changed+=1;saved+=len(body)-len(replacement)
    if len(updates)>=256:db.executemany('UPDATE values_v1 SET body=? WHERE key=?',updates);updates=[]
   if updates:db.executemany('UPDATE values_v1 SET body=? WHERE key=?',updates)
   db.commit();db.execute('VACUUM');after,verified=logical(db);integrity=db.execute('PRAGMA integrity_check').fetchone()[0];db.close()
   if before!=after or records!=verified or integrity!='ok' or sha(source)!=original_hash:raise ValueError('Lossless recompression validation failed')
   # Retain the smallest validated database; never expand a resource.
   keep=working.stat().st_size<existing.stat().st_size
   if keep:
    destination.parent.mkdir(parents=True,exist_ok=True);os.replace(working,destination)
   result={'source':str(source),'originalSHA256':original_hash,'originalBytes':source.stat().st_size,'optimizedBytes':destination.stat().st_size if destination.exists() else source.stat().st_size,'recompressedRecords':changed if keep else 0,'verifiedRecords':verified,'logicalSHA256':before,'integrity':integrity,'sourceUnchanged':True}
   if destination.exists():
    m=json.loads((source.parent.parent/'manifest.json').read_text());m['normalizedContent'].update(sha256=sha(destination),byteCount=destination.stat().st_size);(destination.parent.parent/'manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n');result['optimizedSHA256']=m['normalizedContent']['sha256']
   results.append(result)
  (a.output/'recompression-validation.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
  if i%20==0:print('Validated:',i,'saved bytes:',sum(r['originalBytes']-r['optimizedBytes'] for r in results),flush=True)
 summary={'databases':len(results),'optimizedDatabases':sum(r['optimizedBytes']<r['originalBytes'] for r in results),'originalBytes':sum(r['originalBytes'] for r in results),'optimizedBytes':sum(r['optimizedBytes'] for r in results),'verifiedRecords':sum(r['verifiedRecords'] for r in results),'sourceLibraryUnchanged':True,'allDecodedRecordsVerified':True}
 (a.output/'recompression-summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2),flush=True)
if __name__=='__main__':main()
