#!/usr/bin/env python3
"""Build resumable private resource collections. Never upload or alter the library."""
import argparse, collections, hashlib, json, os, secrets, shutil, subprocess, tempfile, urllib.parse, zipfile
from pathlib import Path

def encoded(value): return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
def write(path,value): path.write_bytes(encoded(value))
def digest(data): return hashlib.sha256(data).hexdigest()
def local(url): return Path(urllib.parse.unquote(urllib.parse.urlparse(url).path))
def main():
 p=argparse.ArgumentParser();p.add_argument('--library',type=Path,required=True);p.add_argument('--hidden',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--crypto-tool',type=Path,required=True);a=p.parse_args()
 out=a.output;out.mkdir(parents=True,exist_ok=True);os.chmod(out,0o700)
 private=out/'private';private.mkdir(exist_ok=True);os.chmod(private,0o700)
 keyfile=private/'recovery-key.txt'
 if not keyfile.exists(): keyfile.write_text(''.join(secrets.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789') for _ in range(30)));os.chmod(keyfile,0o600)
 rs=json.loads((a.library/'catalog.json').read_text())['resources'];hidden={r['id'] for r in json.loads(a.hidden.read_text())['hidden']};visible=[r for r in rs if r['id'] not in hidden];by_path={local(r['packageLocation']).resolve():r for r in rs}
 names={'en':'English','es':'Spanish','pt':'Portuguese','fr':'French','de':'German','it':'Italian','grc':'Ancient Greek','el':'Greek','he':'Hebrew','la':'Latin','ar':'Arabic','zh':'Chinese','ru':'Russian','und':'Unspecified Language'}
 groups=collections.defaultdict(list);all_entries={};receipt=[];raw_bytes=0
 def package(r,dependency=False):
  nonlocal raw_bytes
  source=local(r['packageLocation']);m=json.loads((source/'manifest.json').read_text());deps=[]
  for e in m['metadata'].get('evidence',[]):
   if e['field']=='strongVariantPackage':
    dependency_path=Path(e['value']).resolve();dep=by_path[dependency_path];deps.append(package(dep,True));e['value']=dependency_path.name
  files=sorted(f for f in source.rglob('*') if f.is_file() and not f.name.startswith('._'))
  if any(f.is_symlink() for f in source.rglob('*')): raise ValueError('Symlink in resource: '+source.name)
  tree=hashlib.sha256();members=[]
  for f in files:
   relative=f.relative_to(source).as_posix();data=encoded(m) if relative=='manifest.json' else f.read_bytes();tree.update(relative.encode()+b'\0'+hashlib.sha256(data).digest());members.append({'path':relative,'sha256':digest(data),'bytes':len(data)})
  identity=tree.hexdigest()
  if identity in all_entries: return all_entries[identity]
  obj=out/'objects'/f'{identity}.lxresource';obj.parent.mkdir(exist_ok=True)
  if not obj.exists():
   with tempfile.TemporaryDirectory(dir=private) as td:
    archive=Path(td)/'resource.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
     for f in files:
      relative=f.relative_to(source).as_posix();z.writestr(source.name+'/'+relative,encoded(m)) if relative=='manifest.json' else z.write(f,source.name+'/'+relative)
    subprocess.run([str(a.crypto_tool),'seal',str(keyfile),str(archive),str(obj)],check=True)
  entry={'id':r['id'],'title':r['title'],'packageName':source.name,'object':obj.relative_to(out).as_posix(),'sha256':digest(obj.read_bytes()),'bytes':obj.stat().st_size,'hidden':dependency,'treeHash':identity,'members':members,'originalManifestSHA':digest((source/'manifest.json').read_bytes())}
  all_entries[identity]=entry;raw_bytes+=sum(f.stat().st_size for f in files)
  receipt.append({'title':r['title'],'type':r.get('libron',{}).get('resourceType'),'languages':r.get('languages',[]),'dependency':dependency,'source':str(source),'object':entry['object']})
  return entry
 for n,r in enumerate(visible,1):
  m=r.get('libron',{});typ=m.get('resourceType','Other');lang=(m.get('languages') or r.get('languages') or ['und'])[0].split('-')[0].lower();language=names.get(lang,lang.upper())
  if typ=='Biblia': group=language+' Bibles'
  elif typ=='Comentario bíblico': group=language+' Bible Commentaries'
  elif typ in ['Diccionario o enciclopedia','Léxico']:group='Dictionaries and Lexicons'
  else: group={'Atlas':'Atlases and Maps','Concordancia':'Concordances','Manual o curso':'Manuals and Courses','Devocional':'Devotionals','Sermonario o bosquejos':'Sermons and Outlines','Gramática':'Grammars'}.get(typ,'Study Books')
  entry=package(r);groups[group].append(entry)
  for e in m.get('evidence',[]):
   if e['field']=='strongVariantPackage':groups[group].append(package(by_path[Path(e['value']).resolve()],True))
  if n%25==0: print(f'Prepared {n}/{len(visible)}',flush=True)
 # Preserve fonts used by native resources without putting personal state in a collection.
 fonts=a.library/'Setup'/'Fonts'
 if fonts.exists():
  support=private/'Reading Fonts.libron'
  # Font files are delivered separately from resource packages for publisher finalization.
  target=out/'support'/'Fonts';target.mkdir(parents=True,exist_ok=True)
  for f in fonts.iterdir():
   if f.is_file() and not f.name.startswith('.'):shutil.copy2(f,target/f.name)
 collections_out=[]
 for title,entries in sorted(groups.items()):
  entries=list({e['id']:e for e in entries}.values());slug='-'.join(title.lower().split());manifest={'schemaVersion':1,'id':slug,'title':title,'resources':entries};write(private/(slug+'.json'),manifest);collections_out.append({'id':slug,'title':title,'resources':len([e for e in entries if not e['hidden']]),'files':len(entries),'bytes':sum(e['bytes'] for e in entries)})
 write(private/'all-resources.json',{'schemaVersion':1,'id':'all-resources','title':'All Resources','resources':list(all_entries.values())})
 summary={'status':'Prepared locally; not uploaded; download codes pending hosting','visibleResources':len(visible),'dependencyResources':sum(e['hidden'] for e in all_entries.values()),'bundledDictionaries':'12 already shipped with the application; not duplicated','sourceBytes':raw_bytes,'encryptedBytes':sum(e['bytes'] for e in all_entries.values()),'collections':collections_out}
 write(out/'inventory.json',{'summary':summary,'resources':receipt});write(out/'summary.json',summary)
 titles=['All Resources']+[c['title'] for c in collections_out]
 (out/'Download Codes.txt').write_text('LIBRON-X DOWNLOAD CODES\n\nStatus: NOT UPLOADED. No working remote download codes exist yet.\nA free hosting account and verified uploaded links are required.\nKeep the recovery key private.\n\n'+'\n\n'.join(t+' — Download code:\nPENDING UPLOAD' for t in titles)+'\n')
 print(json.dumps(summary,ensure_ascii=False,indent=2),flush=True)
if __name__=='__main__':main()
