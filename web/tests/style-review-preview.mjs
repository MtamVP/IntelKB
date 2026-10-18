import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';
const root=fileURLToPath(new URL('../dist/',import.meta.url)),db=new PGlite(),port=Number(process.argv[2]||8772),owner='10000000-0000-4000-8000-000000000001';
for(const command of [`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to anon,authenticated;`,...['20261017_community_moderation.sql','20261018_review_tools.sql','20261018_entry_changes.sql','20261018_style_review.sql'].map(name=>fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'))])await db.exec(command);
await db.query('insert into auth.users(id) values($1)',[owner]);await db.query('insert into public.intelkb_admins values($1)',[owner]);
await db.exec("insert into public.intelkb_dictionary(trigger,expansion,category,source) values('zz','tục một','profanity','bootstrap'),('zz','tục hai','profanity','bootstrap'),('zz','nhẹ một','chat','bootstrap'),('zz','nhẹ hai','euphemism','bootstrap'),('pair','nghĩa tục','profanity','bootstrap'),('pair','nghĩa nhẹ','chat','bootstrap'),('dc','được','chat','bootstrap');");
const original=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,status) values('hnay','hôm nay','chat','approved') returning id,revision")).rows[0];
await db.query("select public.intelkb_submit_proposal('20000000-0000-4000-8000-000000000001','edit','hnay','ngày hôm nay','chat',true,$1,$2)",[original.id,original.revision]);
let serial=Promise.resolve();
const rpc=new Set(['intelkb_is_admin','intelkb_check_entry','intelkb_review_queue','intelkb_review_context','intelkb_review_commit','intelkb_last_review','intelkb_undo_review','intelkb_set_style_defaults','intelkb_submit_proposal']);
function reply(res,value,status=200,type='application/json'){res.writeHead(status,{'Content-Type':type+'; charset=utf-8','Cache-Control':'no-store'});res.end(type==='application/json'?JSON.stringify(value):value);}
http.createServer(async(req,res)=>{
 try{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/config.mjs')return reply(res,`export const SUPABASE_CONFIG={url:'http://127.0.0.1:${port}',publishableKey:'fixture-only'};`,200,'text/javascript');
 if(url.pathname.startsWith('/auth/v1/token'))return reply(res,{access_token:'fixture-only',refresh_token:'fixture-only',expires_in:3600,user:{id:owner}});
 if(url.pathname.startsWith('/auth/v1/logout'))return reply(res,{});
 if(url.pathname.startsWith('/rest/v1/')){
  let body='';for await(const chunk of req){body+=chunk;if(body.length>1000000)throw new Error('Too large');}
  const input=body?JSON.parse(body):{};
  serial=serial.catch(()=>{}).then(async()=>{
   try{
    await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[req.headers.authorization==='Bearer fixture-only'?owner:'']);await db.exec('set role '+(req.headers.authorization==='Bearer fixture-only'?'authenticated':'anon'));
    if(url.pathname==='/rest/v1/intelkb_dictionary'){
     const select=url.searchParams.get('select')||'*';if(!/^(\*|[a-z_,]+)$/.test(select))throw new Error('Invalid columns');
     const rows=await db.query(`select ${select} from public.intelkb_dictionary where status='approved' order by id limit 1000`);return reply(res,rows.rows);
    }
    const name=url.pathname.split('/').at(-1);if(!rpc.has(name))throw new Error('Unknown local fixture RPC');
    const entries=Object.entries(input);if(entries.some(([key])=>!/^p_[a-z_]+$/.test(key)))throw new Error('Invalid arguments');
    const result=await db.query(`select public.${name}(${entries.map(([key],i)=>key+'=> $'+(i+1)).join(',')}) as value`,entries.map(([,v])=>v!==null&&typeof v==='object'?JSON.stringify(v):v));reply(res,result.rows[0].value);
   }catch(error){reply(res,{message:error.message,code:error.code},400);}
  });return;
 }
 const file=path.resolve(root,'.'+(url.pathname==='/'?'/index.html':decodeURIComponent(url.pathname)));
 if(!file.startsWith(path.resolve(root)+path.sep)){reply(res,{},403);return;}
 let content=fs.readFileSync(file);const ext=path.extname(file),type={'.html':'text/html','.css':'text/css','.mjs':'text/javascript','.js':'text/javascript','.json':'application/json','.sql':'text/plain'}[ext]||'application/octet-stream';
 if(ext==='.html')content=content.toString().replace('<body>','<body><div style="padding:8px;background:#493e22;color:#f1ddb2;text-align:center;font:11px system-ui">DỮ LIỆU THỬ CỤC BỘ · KHÔNG KẾT NỐI SUPABASE THẬT</div>');
 reply(res,ext==='.json'?JSON.parse(content.toString()):content.toString(),200,type);
 }catch(error){reply(res,{message:error.message},404);}
}).listen(port,'127.0.0.1',()=>console.log('Disposable PostgreSQL UI fixture: http://127.0.0.1:'+port+'/workbench-ink-7c91.html'));
