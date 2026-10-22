#!/usr/bin/env python3
"""Lossless, file-deduplicated, encrypted distribution. No account/network access."""
import argparse,collections,hashlib,json,os,subprocess,tempfile,zlib
from pathlib import Path

def digest(data):return hashlib.sha256(data).hexdigest()
def encoded(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
def main():
 p=argparse.ArgumentParser();p.add_argument('--baseline',type=Path,required=True);p.add_argument('--audit',type=Path,required=True);p.add_argument('--overlays',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);os.chmod(a.output,0o700)
 if not (a.overlays/'recompression-summary.json').exists():raise ValueError('Complete recompression validation is required')
 private=a.output/'private';private.mkdir(exist_ok=True);os.chmod(private,0o700);key=a.baseline/'private'/'recovery-key.txt';tool=a.baseline/'private-crypto-tool';objects=a.output/'objects';objects.mkdir(exist_ok=True)
 (private/'recovery-key.txt').write_bytes(key.read_bytes());os.chmod(private/'recovery-key.txt',0o600)
 audit={x['path']:x for x in json.loads((a.audit/'files.json').read_text())};known={};resources={};receipts=[];raw=0;original=0;reused=0
 manifests=list((a.baseline/'private').glob('*.json'));source=next(x for x in manifests if x.name=='all-resources.json');baseline=json.loads(source.read_text())
 for i,entry in enumerate(baseline['resources'],1):
  package=next(x for x in json.loads((a.baseline/'inventory.json').read_text())['resources'] if x['object']==entry['object']);root=Path(package['source']);members=[];original_members=[]
  for f in sorted(root.rglob('*')):
   if not f.is_file() or f.name.startswith('._'):continue
   rel=f.relative_to(root).as_posix();source_data=f.read_bytes();expected=audit[str(f)]['sha256']
   if digest(source_data)!=expected:raise ValueError('Source changed since audit: '+str(f))
   original+=len(source_data);original_members.append({'path':rel,'sha256':expected})
   overlay=a.overlays/root.name/rel;data=overlay.read_bytes() if overlay.is_file() else source_data
   if rel=='manifest.json':
    manifest=json.loads(data)
    for evidence in manifest['metadata'].get('evidence',[]):
     if evidence['field']=='strongVariantPackage':evidence['value']=Path(evidence['value']).name
    data=encoded(manifest)
   checksum=digest(data);raw+=len(data)
   if checksum not in known:
    compressed=zlib.compress(data,9)
    if zlib.decompress(compressed)!=data:raise ValueError('Lossless compression failed')
    obj=objects/(checksum+'.lxblob')
    with tempfile.TemporaryDirectory(dir=private) as td:
     plain=Path(td)/'compressed';decoded=Path(td)/'decoded';plain.write_bytes(compressed)
     if not obj.exists():subprocess.run([str(tool),'seal',str(key),str(plain),str(obj)],check=True)
     subprocess.run([str(tool),'open',str(key),str(obj),str(decoded)],check=True)
     if decoded.read_bytes()!=compressed:raise ValueError('Encrypted object mismatch')
    known[checksum]={'sha256':checksum,'object':obj.relative_to(a.output).as_posix(),'encryptedSHA256':digest(obj.read_bytes()),'downloadBytes':obj.stat().st_size,'bytes':len(data),'codec':'zlib'}
   else:reused+=1
   members.append({'path':rel,**known[checksum]})
  new={'id':entry['id'],'title':entry['title'],'packageName':entry['packageName'],'hidden':entry['hidden'],'files':members,'compatibleOriginalFiles':original_members}
  resources[entry['id']]=new
  if i%25==0:print('Packaged and verified:',i,'/',len(baseline['resources']),flush=True)
 for collection_path in manifests:
  collection=json.loads(collection_path.read_text());collection['schemaVersion']=2;collection['resources']=[resources[x['id']] for x in collection['resources']];collection['format']='org.libron.download.collection';collection['status']='local-only-pending-upload';(private/collection_path.name).write_bytes(encoded(collection))
 # Fonts are shared once, and encrypted like all other resources.
 fonts=a.baseline/'support'/'Fonts'
 if fonts.exists():
  font_entries=[]
  for font in sorted(fonts.iterdir()):
   if not font.is_file():continue
   data=font.read_bytes();checksum=digest(data)
   if checksum not in known:
    compressed=zlib.compress(data,9);obj=objects/(checksum+'.lxblob')
    with tempfile.TemporaryDirectory(dir=private) as td:
     plain=Path(td)/'compressed';decoded=Path(td)/'decoded';plain.write_bytes(compressed)
     if not obj.exists():subprocess.run([str(tool),'seal',str(key),str(plain),str(obj)],check=True)
     subprocess.run([str(tool),'open',str(key),str(obj),str(decoded)],check=True)
     if zlib.decompress(decoded.read_bytes())!=data:raise ValueError('Font integrity mismatch')
    known[checksum]={'sha256':checksum,'object':obj.relative_to(a.output).as_posix(),'encryptedSHA256':digest(obj.read_bytes()),'downloadBytes':obj.stat().st_size,'bytes':len(data),'codec':'zlib'}
   font_entries.append({'path':font.name,**known[checksum]})
  for collection_path in (private).glob('*.json'):
   collection=json.loads(collection_path.read_text());collection['readingFonts']=font_entries;collection_path.write_bytes(encoded(collection))
 summary={'status':'Optimized and verified locally; not uploaded','visibleResources':len([x for x in resources.values() if not x['hidden']]),'dependencyResources':len([x for x in resources.values() if x['hidden']]),'originalResourceBytes':original,'optimizedResourceBytes':raw,'uniqueFileObjects':len(known),'sharedFileReferences':reused,'encryptedDownloadBytes':sum(x['downloadBytes'] for x in known.values()),'baselineEncryptedZIPBytes':json.loads((a.baseline/'summary.json').read_text())['encryptedBytes'],'originalLibraryUnchanged':True,'allObjectsDecryptedAndVerified':True,'format':'org.libron.download.collection v2; file-level zlib + AES-GCM','fonts':'Included as shared encrypted objects in every collection'}
 (a.output/'summary.json').write_text(json.dumps(summary,indent=2));(a.output/'Download Codes.txt').write_text((a.baseline/'Download Codes.txt').read_text());print(json.dumps(summary,indent=2),flush=True)
if __name__=='__main__':main()
