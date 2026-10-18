import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';

test('full-entry changes allow metadata edits and distinct pending variants, but block no-op and full duplicates',async()=>{
 const db=new PGlite(),owner='10000000-0000-4000-8000-000000000001';
 try{
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text);
   create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to anon,authenticated;`);
  for(const name of ['20261017_community_moderation.sql','20261018_review_tools.sql','20261018_entry_changes.sql','20261018_entry_changes.sql'])await db.exec(fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
  await db.query('insert into auth.users(id) values($1)',[owner]);await db.query('insert into public.intelkb_admins values($1)',[owner]);
  const word=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,status,source) values('abc','nghĩa mới','chat','approved','bootstrap') returning *")).rows[0];
  let serial=0;
  const submit=async(category='chat',auto=false,action='new',target=null,rev=null,receipt=null)=>(await db.query("select public.intelkb_submit_proposal($1,$2,'ABC','NGHĨA MỚI',$3,$4,$5,$6) as v",[receipt||`20000000-0000-4000-8000-${String(++serial).padStart(12,'0')}`,action,category,auto,target,rev])).rows[0].v;
  await db.exec('set role anon');
  await assert.rejects(submit(),/No changes/);
  await assert.rejects(submit('chat',false,'edit',word.id,word.revision),/No changes/);
  const changed=await submit('chat',true);
  const receipt='20000000-0000-4000-8000-000000000099';
  const category=await submit('english',false,'edit',word.id,word.revision,receipt);
  assert.ok(changed.id);assert.ok(category.id);
  await assert.rejects(submit('chat',true),/identical/);
  const check=async(cat,auto)=>(await db.query("select public.intelkb_check_entry(' aBc ','nghĩa  mới',$1,$2) as v",[cat,auto])).rows[0].v;
  assert.deepEqual(await check('chat',false),{match:'published'});
  assert.deepEqual(await check('chat',true),{match:'pending'});
  assert.deepEqual(await check('english',true),{match:'none'});
  await assert.rejects(db.query('select * from public.intelkb_proposals'),/permission denied/);
  await db.exec('reset role');
  const saved=(await db.query('select * from public.intelkb_proposals where id=$1',[changed.id])).rows[0];
  assert.equal(saved.action,'edit');assert.equal(saved.target_id,word.id);assert.equal(saved.base_revision,word.revision);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[owner]);await db.exec('set role authenticated');
  await db.query("select public.intelkb_review_proposal($1,'accept')",[changed.id]);
  assert.equal((await db.query('select auto_replace from public.intelkb_dictionary where id=$1',[word.id])).rows[0].auto_replace,true);
  await assert.rejects(db.query("select public.intelkb_review_proposal($1,'accept')",[category.id]),/changed/);
  await db.exec('set role anon');
  assert.equal((await submit('english',false,'edit',word.id,word.revision,receipt)).id,category.id);
  const renamed=(await db.query("select public.intelkb_submit_proposal('30000000-0000-4000-8000-000000000001','edit','abcd','nghĩa mới','chat',true,$1,2) as v",[word.id])).rows[0].v;
  await db.exec('set role authenticated');
  await db.query("select public.intelkb_review_proposal($1,'accept')",[renamed.id]);
  const final=(await db.query('select trigger,revision from public.intelkb_dictionary where id=$1',[word.id])).rows[0];
  assert.equal(final.trigger,'abcd');assert.equal(final.revision,3);

 }finally{await db.close();}
});
