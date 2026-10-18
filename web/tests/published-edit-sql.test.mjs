import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';

test('published editing checks owner, revision and duplicates, preserves choices, and supports undo',async()=>{
 const db=new PGlite(),owner='10000000-0000-4000-8000-000000000001';let n=0;
 const receipt=()=>`30000000-0000-4000-8000-${String(++n).padStart(12,'0')}`;
 try{
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);
   create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to anon,authenticated;`);
  for(const name of ['20261017_community_moderation.sql','20261018_review_tools.sql','20261018_entry_changes.sql','20261018_style_review.sql','20261018_published_edit.sql','20261018_published_edit.sql'])await db.exec(fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
  await db.query('insert into auth.users(id) values($1)',[owner]);await db.query('insert into public.intelkb_admins values($1)',[owner]);
  const rows=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,status,auto_replace,auto_direct,auto_gentle) values('chs','chẳng hiểu sao','chat','approved',true,true,false),('chs','chơi','chat','approved',true,false,true) returning *")).rows;
  const original=rows[0],entry={trigger:'chs',expansion:'chẳng hiểu sao vậy',category:'chat',auto_replace:false};
  const save=(id,revision,value,r=receipt())=>db.query('select public.intelkb_save_published($1,$2,$3,$4,$5) as v',[r,id,revision,JSON.stringify(value),'owner edit']);
  await db.exec('set role anon');await assert.rejects(save(original.id,1,entry),/permission denied/);
  await db.exec('set role authenticated');await assert.rejects(save(original.id,1,entry),/Administrator required/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[owner]);
  const r=receipt(),report=(await save(original.id,1,entry,r)).rows[0].v;
  assert.ok(report.undo_available);assert.equal((await save(original.id,1,entry,r)).rows[0].v.action_id,report.action_id);
  let current=(await db.query('select * from public.intelkb_dictionary where id=$1',[original.id])).rows[0];
  assert.equal(current.expansion,entry.expansion);assert.equal(current.status,'approved');assert.equal(current.auto_replace,false);assert.equal(current.auto_direct,false);
  assert.equal((await db.query('select auto_gentle from public.intelkb_dictionary where id=$1',[rows[1].id])).rows[0].auto_gentle,true);
  await assert.rejects(save(original.id,1,entry),/changed/);
  await assert.rejects(save(original.id,current.revision,{...entry,expansion:'CHƠI'}),/already published/);
  await assert.rejects(save(original.id,current.revision,{...entry,trigger:'new'}),/Cannot rename/);
  await db.query('select public.intelkb_undo_review($1)',[report.action_id]);
  current=(await db.query('select * from public.intelkb_dictionary where id=$1',[original.id])).rows[0];
  assert.equal(current.expansion,original.expansion);assert.ok(current.auto_replace&&current.auto_direct);assert.ok(current.revision>original.revision);
  const changeCategory=(await save(original.id,current.revision,{...entry,auto_replace:true,category:'profanity'})).rows[0].v;
  current=(await db.query('select * from public.intelkb_dictionary where id=$1',[original.id])).rows[0];
  assert.equal(current.auto_gentle,false);assert.equal(current.category,'profanity');
  await db.query('select public.intelkb_undo_review($1)',[changeCategory.action_id]);
  current=(await db.query('select * from public.intelkb_dictionary where id=$1',[original.id])).rows[0];
  const noop=(await save(original.id,current.revision,{trigger:current.trigger,expansion:current.expansion,category:current.category,auto_replace:current.auto_replace})).rows[0].v;
  assert.equal(noop.undo_available,false);
 }finally{await db.close();}
});
