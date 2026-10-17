"""Fetch pinned public datasets and build IntelKB candidate data. Python 3 stdlib only."""
import csv, datetime, hashlib, io, json, pathlib, re, unicodedata, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
HEADERS={'User-Agent':'IntelKB-dataset-collector','Accept':'application/vnd.github+json'}
def fetch(url):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url,headers=HEADERS),timeout=20) as r: return r.read()
        except (OSError, TimeoutError):
            if attempt == 2: raise
def dump(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def norm(text): return ' '.join(unicodedata.normalize('NFC',text).strip().split())
SPECS=[
 ('blue-eyes-vn/vietnamese-offensive-words',['README.md','README_vn.md','LICENSE.md','vn_offensive_words.txt']),
 ('behitek/vietnam-sensitive-words',['README.md','bad_words.json','bad_words_22082018.json','hide.txt']),
 ('ngxtnhi/ViLexNorm',['README.md','data/train.csv','data/dev.csv','data/test.csv']),
 ('AnhHoang0529/ViSoLex-Resources',['README.md','raw_data/ViLexNorm/dictionary/LexNorm_dict_syllable.json','raw_data/ViLexNorm/dictionary/LexNorm_dict_segment.json']),
 ('VFND/VMDS-vietnamese-misspell-dataset-from-Social-media',['README.md','LICENSE','Dataset/dataset.csv'])]
def main():
    sources=[]; errors=[]
    for repo,paths in SPECS:
        sid=repo.replace('/','__'); dest=ROOT/'data/raw'/sid
        try:
            meta=json.loads(fetch('https://api.github.com/repos/'+repo))
            commit=json.loads(fetch('https://api.github.com/repos/'+repo+'/commits/'+meta['default_branch']))['sha']
            lic=(meta.get('license') or {}).get('spdx_id') or 'UNVERIFIED'
            record={'id':sid,'url':'https://github.com/'+repo,'revision':commit,'license':lic,'files':[]}
            for path in paths:
                url='https://raw.githubusercontent.com/'+repo+'/'+commit+'/'+path
                body=fetch(url); target=dest/path; target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(body)
                record['files'].append({'path':str(target.relative_to(ROOT)).replace('\\','/'),'url':url,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest()})
            dump(dest/'source.json',record); sources.append(record)
            print('Downloaded',repo,flush=True)
        except Exception as e: errors.append({'source':repo,'error':str(e)})
    try:
        gid='7d9441c10b3c2739499fc5a4d9ea06fb'; obj=json.loads(fetch('https://api.github.com/gists/'+gid))
        sid='behitek__teencode'; dest=ROOT/'data/raw'/sid; dest.mkdir(parents=True,exist_ok=True)
        body=obj['files']['teencode.txt']['content'].encode('utf-8'); (dest/'teencode.txt').write_bytes(body)
        record={'id':sid,'url':'https://gist.github.com/behitek/'+gid,'revision':obj['history'][0]['version'],'license':'UNVERIFIED','files':[{'path':str((dest/'teencode.txt').relative_to(ROOT)).replace('\\','/'),'url':obj['files']['teencode.txt']['raw_url'],'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest()}]}
        dump(dest/'source.json',record); sources.append(record)
    except Exception as e: errors.append({'source':'behitek__teencode','error':str(e)})
    manifest={'collected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sources':sources,'errors':errors}
    dump(ROOT/'data/sources.json',manifest)
    # Import only successfully downloaded source snapshots; never execute upstream code.
    byid={s['id']:s for s in sources}; candidates={}
    def add(trigger,expansion,sid,location):
        trigger=norm(trigger).lower(); expansion=norm(expansion)
        if not trigger or not expansion or trigger==expansion.lower(): return
        key=(trigger,expansion)
        entry=candidates.setdefault(key,{'trigger':trigger,'expansion':expansion,'review_status':'unreviewed','auto_replace':False,'sources':[]})
        provenance={'source_id':sid,'location':location,'license':byid[sid]['license']}
        if provenance not in entry['sources']: entry['sources'].append(provenance)
    sid='behitek__teencode'
    if sid in byid:
        for i,line in enumerate((ROOT/'data/raw'/sid/'teencode.txt').read_text(encoding='utf-8-sig').splitlines(),1):
            parts=line.split('\t',1)
            if len(parts)==2: add(*parts,sid,'teencode.txt:'+str(i))
    sid='AnhHoang0529__ViSoLex-Resources'
    if sid in byid:
        for name in ['LexNorm_dict_syllable.json','LexNorm_dict_segment.json']:
            path='raw_data/ViLexNorm/dictionary/'+name
            for trigger,values in json.loads((ROOT/'data/raw'/sid/path).read_text(encoding='utf-8-sig')).items():
                for value in values if isinstance(values,list) else [values]:
                    if isinstance(value,str): add(trigger.replace('_',' '),value.replace('_',' '),sid,path+':'+trigger)
    # Keep sentence split provenance; do not use dev/test pairs as dictionary training rows.
    pairs=[]
    for sid,paths,cols in [
        ('ngxtnhi__ViLexNorm',['data/train.csv','data/dev.csv','data/test.csv'],('original','normalized')),
        ('VFND__VMDS-vietnamese-misspell-dataset-from-Social-media',['Dataset/dataset.csv'],('wrong','right'))]:
        if sid not in byid: continue
        for path in paths:
            rows=csv.DictReader((ROOT/'data/raw'/sid/path).read_text(encoding='utf-8-sig').splitlines(keepends=True))
            for i,row in enumerate(rows,2):
                a,b=row.get(cols[0]),row.get(cols[1])
                if a and b: pairs.append({'original':a,'normalized':b,'source_id':sid,'source_row':i,'split':pathlib.Path(path).stem,'license':byid[sid]['license'],'review_status':'upstream_annotation'})
    offensive=[]; sid='blue-eyes-vn__vietnamese-offensive-words'
    if sid in byid:
        group=''
        for i,line in enumerate((ROOT/'data/raw'/sid/'vn_offensive_words.txt').read_text(encoding='utf-8-sig').splitlines(),1):
            line=line.strip()
            if line.startswith('#'):
                if line.strip('# ').strip(): group=line.lstrip('# ').strip()
            elif line: offensive.append({'surface':norm(line),'source_group':group,'expansion':None,'source_id':sid,'source_line':i,'license':byid[sid]['license'],'review_status':'unreviewed','auto_replace':False})
    index={}
    entries=sorted(candidates.values(),key=lambda x:(x['trigger'],x['expansion']))
    for entry in entries: index.setdefault(entry['trigger'],set()).add(entry['expansion'])
    for entry in entries: entry['ambiguous']=len(index[entry['trigger']])>1
    def jsonl(name,rows):
        target=ROOT/'data/processed'/name; target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('w',encoding='utf-8',newline='\n') as f:
            for row in rows: f.write(json.dumps(row,ensure_ascii=False)+'\n')
    jsonl('expansion_candidates.jsonl',entries); jsonl('sentence_pairs.jsonl',pairs); jsonl('offensive_variants.jsonl',offensive)
    summary={'source_count':len(sources),'expansion_pairs':len(entries),'unique_triggers':len(index),'ambiguous_triggers':sum(len(v)>1 for v in index.values()),'sentence_pairs':len(pairs),'offensive_variants':len(offensive),'download_errors':errors}
    dump(ROOT/'data/summary.json',summary)
    print(json.dumps(summary,ensure_ascii=False,indent=2))
    if errors: raise SystemExit(1)
if __name__=='__main__': main()
