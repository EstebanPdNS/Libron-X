#!/usr/bin/env python3
"""Read-only storage audit: visible library, dependencies, exact duplicates and SQLite slack."""
import argparse,collections,hashlib,json,sqlite3,urllib.parse
from pathlib import Path

def local(s):return Path(urllib.parse.unquote(urllib.parse.urlparse(s).path))
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  while b:=f.read(1024*1024):h.update(b)
 return h.hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--library',type=Path,required=True);p.add_argument('--hidden',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 rs=json.loads((a.library/'catalog.json').read_text())['resources'];hs={r['id'] for r in json.loads(a.hidden.read_text())['hidden']};visible=[r for r in rs if r['id'] not in hs];by_path={local(r['packageLocation']).resolve():r for r in rs};selected={r['id']:r for r in visible}
 for r in visible:
  for e in r.get('libron',{}).get('evidence',[]):
   if e['field']=='strongVariantPackage':
    dep=by_path[Path(e['value']).resolve()];selected[dep['id']]=dep
 files=[];sizes=collections.Counter();sqlite=[];packages=[];groups=collections.defaultdict(list)
 for i,r in enumerate(selected.values(),1):
  root=local(r['packageLocation']);total=0
  for f in sorted(root.rglob('*')):
   if not f.is_file() or f.name.startswith('._'):continue
   size=f.stat().st_size;rel=f.relative_to(root).as_posix();category='source' if rel.startswith('content/') else 'native-reader' if rel=='normalized/reader.sqlite' else 'indexes-and-assets' if rel.startswith('normalized/') else 'metadata-and-other'
   digest=sha(f);entry={'path':str(f),'relative':rel,'package':root.name,'title':r['title'],'bytes':size,'sha256':digest,'category':category};files.append(entry);groups[digest].append(entry);sizes[category]+=size;total+=size
   if f.suffix in ['.sqlite','.db']:
    try:
     db=sqlite3.connect(f.as_uri()+'?mode=ro',uri=True);db.execute('PRAGMA query_only=ON');page=db.execute('PRAGMA page_size').fetchone()[0];free=db.execute('PRAGMA freelist_count').fetchone()[0];tables=[x[0] for x in db.execute("SELECT name FROM sqlite_master WHERE type='table'")];body=None
     if 'values_v1' in tables:body=db.execute('SELECT COUNT(*),SUM(length(body)),SUM(size) FROM values_v1').fetchone()
     sqlite.append({'path':str(f),'bytes':size,'freeBytes':page*free,'tables':tables,'values':body});db.close()
    except sqlite3.Error as e:sqlite.append({'path':str(f),'error':str(e)})
  packages.append({'title':r['title'],'path':str(root),'bytes':total,'dependency':r['id'] in hs})
  if i%50==0:print(f'Audited {i}/{len(selected)}',flush=True)
 duplicates=[{'sha256':h,'bytesEach':g[0]['bytes'],'copies':len(g),'savingBytes':g[0]['bytes']*(len(g)-1),'paths':[x['path'] for x in g]} for h,g in groups.items() if len(g)>1];duplicates.sort(key=lambda d:d['savingBytes'],reverse=True)
 summary={'visibleResources':len(visible),'dependencyResources':len(selected)-len(visible),'files':len(files),'sourceBytes':sum(x['bytes'] for x in files),'exactDuplicateSavingBytes':sum(x['savingBytes'] for x in duplicates),'uniqueBytes':sum(g[0]['bytes'] for g in groups.values()),'sqliteFreeBytes':sum(x.get('freeBytes',0) for x in sqlite),'categories':dict(sizes),'excludedHiddenResources':len(rs)-len(selected),'policy':'Original library unchanged. No content removed. Hidden Strong dependencies retained.'}
 for name,value in [('summary',summary),('files',files),('duplicates',duplicates),('sqlite',sqlite),('packages',sorted(packages,key=lambda x:x['bytes'],reverse=True))]: (a.output/(name+'.json')).write_text(json.dumps(value,ensure_ascii=False,indent=2))
 print(json.dumps(summary,indent=2),flush=True)
if __name__=='__main__':main()
