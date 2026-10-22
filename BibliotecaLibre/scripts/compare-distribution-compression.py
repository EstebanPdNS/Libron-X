#!/usr/bin/env python3
"""Compare portable archive codecs using complete resource packages, without modifying them."""
import argparse,json,lzma,tarfile,time,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--audit',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
packages=json.loads((a.audit/'packages.json').read_text());wanted=['Merriam-Webster\'s collegiate','Interlineal inverso del Antiguo','NKJV Study Bible, Full-Color'];selected=[next(x for x in packages if x['title'].startswith(prefix)) for prefix in wanted];results=[]
for i,item in enumerate(selected):
 root=Path(item['path']);result={'title':item['title'],'sourceBytes':item['bytes']}
 for codec in ['zip9','xz6']:
  start=time.monotonic();archive=a.output/f'sample-{i}.{codec}'
  if codec=='zip9':
   with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for f in sorted(root.rglob('*')):
     if f.is_file() and not f.name.startswith('._'):z.write(f,root.name+'/'+f.relative_to(root).as_posix())
   with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None:raise ValueError('ZIP checksum failure')
  else:
   with lzma.open(archive,'wb',preset=6) as output:
    with tarfile.open(fileobj=output,mode='w|') as t:t.add(root,arcname=root.name)
   with tarfile.open(archive,mode='r:xz') as t:
    import hashlib
    for member in t:
     if member.isfile():
      relative=Path(member.name).relative_to(root.name);data=t.extractfile(member).read()
      if hashlib.sha256(data).digest()!=hashlib.sha256((root/relative).read_bytes()).digest():raise ValueError('XZ content mismatch')
  result[codec]={'bytes':archive.stat().st_size,'seconds':round(time.monotonic()-start,2),'verified':True};archive.unlink();print(item['title'][:60],codec,result[codec],flush=True)
 results.append(result);(a.output/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
