#!/usr/bin/env python3
"""Create validated reader/manifest overlays; never write to installed resources."""
import argparse,hashlib,json,math,sqlite3
from pathlib import Path
import importlib.util
spec=importlib.util.spec_from_file_location('storage_benchmark',Path(__file__).with_name('benchmark-native-storage.py'));benchmark=importlib.util.module_from_spec(spec);spec.loader.exec_module(benchmark)

def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  while b:=f.read(1048576):h.update(b)
 return h.hexdigest()
def recommend(db):
 # Model WITHOUT ROWID index cells, their local payload and overflow pages.
 histogram=db.execute('SELECT length(body)+length(key)+90,COUNT(*) FROM values_v1 GROUP BY 1').fetchall()
 scores={}
 for page in [4096,8192,16384,32768,65536]:
  low=math.floor((page-12)*32/255)-23;high=math.floor((page-12)*64/255)-23;cost=0
  for payload,n in histogram:
   local=payload
   if payload>high:
    local=low+(payload-low)%(page-4)
    if local>high:local=low
   cost+=n*((local+8)/0.85+math.ceil((payload-local)/(page-4))*page)
  scores[page]=cost
 return min(scores,key=scores.get)
def main():
 p=argparse.ArgumentParser();p.add_argument('--audit',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);results=[]
 for i,item in enumerate(json.loads((a.audit/'sqlite.json').read_text()),1):
  path=Path(item['path'])
  if path.name!='reader.sqlite' or path.parent.name!='normalized':continue
  db=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True);page=recommend(db);original=path.stat().st_size;original_hash=sha(path)
  result={'source':str(path),'originalBytes':original,'originalSHA256':original_hash,'proposedPageSize':page,'changed':False}
  if page!=db.execute('PRAGMA page_size').fetchone()[0] or item.get('freeBytes',0)>0:
   dest=a.output/path.parent.parent.name/'normalized'/'reader.sqlite';dest.parent.mkdir(parents=True,exist_ok=True);dest.unlink(missing_ok=True)
   db.execute('PRAGMA page_size='+str(page));db.execute('VACUUM INTO ?', (str(dest),));candidate=sqlite3.connect(dest.as_uri()+'?mode=ro',uri=True)
   original_digest=benchmark.digest_rows(db);candidate_digest=benchmark.digest_rows(candidate);integrity=candidate.execute('PRAGMA integrity_check').fetchone()[0];candidate.close()
   if original_digest!=candidate_digest or integrity!='ok' or sha(path)!=original_hash:raise ValueError('Content validation failed: '+str(path))
   if dest.stat().st_size<original:
    m=json.loads((path.parent.parent/'manifest.json').read_text());m['normalizedContent']['sha256']=sha(dest);m['normalizedContent']['byteCount']=dest.stat().st_size
    (dest.parent.parent/'manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n')
    result.update(changed=True,optimizedBytes=dest.stat().st_size,optimizedSHA256=m['normalizedContent']['sha256'],logicalSHA256=original_digest,integrity=integrity,sourceUnchanged=True)
   else:dest.unlink()
  db.close();results.append(result)
  (a.output/'validation.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
  if i%20==0:print('Validated databases:',i,'saved bytes:',sum(r['originalBytes']-r['optimizedBytes'] for r in results if r['changed']),flush=True)
 summary={'databases':len(results),'optimizedDatabases':sum(r['changed'] for r in results),'originalBytes':sum(r['originalBytes'] for r in results),'optimizedBytes':sum(r.get('optimizedBytes',r['originalBytes']) for r in results),'sourceLibraryUnchanged':True,'logicalRowsVerifiedForEveryChangedDatabase':True}
 (a.output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2),flush=True)
if __name__=='__main__':main()
