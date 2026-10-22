#!/usr/bin/env python3
"""Measure SQLite page layouts in disposable copies; compare logical rows exactly."""
import argparse,hashlib,json,sqlite3,struct,zlib
from pathlib import Path

def digest_rows(db):
 h=hashlib.sha256()
 schema=db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
 h.update(json.dumps(schema,ensure_ascii=False).encode())
 for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall():
  columns=db.execute('PRAGMA table_info("'+table+'")').fetchall();order=[c[1] for c in sorted(columns,key=lambda x:x[5]) if c[5]] or [c[1] for c in columns]
  query='SELECT * FROM "'+table+'" ORDER BY '+','.join('"'+c+'"' for c in order)
  for row in db.execute(query):
   for value in row:
    b=value if isinstance(value,bytes) else json.dumps(value,ensure_ascii=False).encode();h.update(type(value).__name__.encode()+b'\0'+struct.pack('>Q',len(b))+b)
 return h.hexdigest()
def compressed_size(path):
 z=zlib.compressobj(9);total=0
 with path.open('rb') as f:
  while b:=f.read(1024*1024):total+=len(z.compress(b))
 return total+len(z.flush())
def main():
 p=argparse.ArgumentParser();p.add_argument('--samples',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);results=[]
 for i,item in enumerate(json.loads(a.samples.read_text())):
  path=Path(item['path']);db=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True);baseline=digest_rows(db);basezip=compressed_size(path);rows=[]
  for page in [8192,16384,32768,65536]:
   candidate=a.output/f'sample-{i}-{page}.sqlite';candidate.unlink(missing_ok=True)
   db.execute('PRAGMA page_size='+str(page));db.execute('VACUUM INTO ?', (str(candidate),));copy=sqlite3.connect(candidate.as_uri()+'?mode=ro',uri=True)
   same=digest_rows(copy)==baseline;integrity=copy.execute('PRAGMA integrity_check').fetchone()[0];actual_page=copy.execute('PRAGMA page_size').fetchone()[0];copy.close()
   result={'pageSize':actual_page,'bytes':candidate.stat().st_size,'compressedBytes':compressed_size(candidate),'logicalRowsIdentical':same,'integrity':integrity};rows.append(result);candidate.unlink();print(path.parent.parent.name[:65],result,flush=True)
   if not same or integrity!='ok':raise ValueError('Invalid optimization')
  db.close();results.append({'path':str(path),'originalBytes':path.stat().st_size,'originalCompressedBytes':basezip,'logicalSHA256':baseline,'candidates':rows});(a.output/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
