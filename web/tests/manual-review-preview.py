"""Local UI fixture only: python web/tests/manual-review-preview.py (port 8770).
Never connects to Supabase; all accounts, rows and decisions are disposable test data.
"""
import json, pathlib, urllib.parse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
ROOT=pathlib.Path(__file__).resolve().parents[1]/'dist'
ROWS=[]
for i,(trigger,meaning,category) in enumerate([
 ('xl','xin lỗi','chat'),('XL','xạo lồn','profanity'),('hnay','hôm nay','chat'),('ms','mới','chat'),
 ('ko','không','chat'),('k0','không','chat'),('nhg','nhưng','chat'),('nhiu','nhiều','chat'),
 ('vcl','vãi cả lồn','profanity'),('vcl','vãi cả lúa','euphemism'),('dc','được','chat'),('tks','cảm ơn','chat')]):
 ROWS.append(dict(id=f'10000000-0000-4000-8000-{i+1:012d}',trigger=trigger,expansion=meaning,category=category,
  auto_replace=False,status='draft',source='bootstrap',revision=1,created_at='2026-10-18T01:00:00Z'))
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(ROOT),**kwargs)
 def send_value(self,data,status=200,mime='application/json'):
  body=(json.dumps(data,ensure_ascii=False) if mime=='application/json' else data).encode()
  self.send_response(status);self.send_header('Content-Type',mime+'; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_GET(self):
  if self.path.startswith('/config.mjs'):
   return self.send_value("export const SUPABASE_CONFIG={url:'http://127.0.0.1:8770',publishableKey:'local-test'};",mime='text/javascript')
  if self.path.startswith('/workbench-ink-7c91.html'):
   html=(ROOT/'workbench-ink-7c91.html').read_text(encoding='utf-8').replace('<body>','<body><div style="padding:8px;background:#463f20;color:#eadb9d;text-align:center;font:11px system-ui">BẢN KIỂM TRA CỤC BỘ · DỮ LIỆU GIẢ · KHÔNG KẾT NỐI SUPABASE</div>')
   return self.send_value(html,mime='text/html')
  if self.path.startswith('/rest/v1/intelkb_dictionary'):return self.send_value([])
  return super().do_GET()
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or b'{}')
  if self.path.startswith('/auth/v1/token'):
   return self.send_value(dict(access_token='fixture-only',refresh_token='fixture-only',expires_in=3600,user=dict(id='20000000-0000-4000-8000-000000000001')))
  if self.path.startswith('/auth/v1/logout'):return self.send_value({})
  if self.path.endswith('/intelkb_is_admin'):return self.send_value(self.headers.get('Authorization')=='Bearer fixture-only')
  if self.path.endswith('/intelkb_check_pair'):return self.send_value(dict(match='none'))
  if self.headers.get('Authorization')!='Bearer fixture-only':return self.send_value(dict(message='Administrator required'),403)
  if self.path.endswith('/intelkb_review_queue'):
   status={'pending':'draft','accepted':'approved','rejected':'rejected'}[body.get('p_status','pending')]
   query=body.get('p_search','').lower();category=body.get('p_category','')
   rows=[r for r in ROWS if r['status']==status and (not category or r['category']==category) and query in (r['trigger']+' '+r['expansion']).lower()] if body.get('p_kind')=='seeds' else []
   if body.get('p_grouped'):rows.sort(key=lambda r:r['trigger'].lower())
   offset=body.get('p_offset',0)
   return self.send_value(dict(rows=rows[offset:offset+50],total=len(rows),counts=dict(seeds=sum(r['status']=='draft' for r in ROWS),proposals=0,approved=sum(r['status']=='approved' for r in ROWS))))
  if self.path.endswith('/intelkb_review_batch'):
   results=[]
   for item in body['p_items']:
    row=next((r for r in ROWS if r['id']==item['id']),None)
    if row and row['status']=='draft' and row['revision']==item['revision']:
     row.update(item.get('override') or {});row.update(body.get('p_options') or {});row['status']='approved' if body['p_decision']=='accept' else 'rejected';row['revision']+=1
     results.append(dict(id=item['id'],ok=True))
    else:results.append(dict(id=item['id'],ok=False,error='Entry changed'))
   return self.send_value(dict(rows=results,ok=sum(r['ok'] for r in results),failed=sum(not r['ok'] for r in results)))
  return self.send_value(dict(message='Not implemented'),404)
print('Local fixture: http://127.0.0.1:8770/workbench-ink-7c91.html',flush=True)
ThreadingHTTPServer(('127.0.0.1',8770),Handler).serve_forever()
