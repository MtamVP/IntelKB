import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';


test('mode defaults, batch idempotence, private history and conflict-safe undo',async()=>{
 const db=new PGlite(),owner='10000000-0000-4000-8000-000000000001';let seq=0;
 const receipt=()=>`30000000-0000-4000-8000-${String(++seq).padStart(12,'0')}`;
 try{
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text);
   create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to anon,authenticated;`);
  for(const name of ['20261017_community_moderation.sql','20261018_review_tools.sql','20261018_entry_changes.sql','20261018_style_review.sql','20261018_style_review.sql'])await db.exec(fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
  await db.query('insert into auth.users(id) values($1)',[owner]);await db.query('insert into public.intelkb_admins values($1)',[owner]);
  const seeds=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,source) values('zz','tục một','profanity','bootstrap'),('ZZ','nhẹ một','chat','bootstrap'),('zz','tục hai','profanity','bootstrap') returning *")).rows;
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[owner]);await db.exec('set role authenticated');
  const commit=async(items,choices=[],id=receipt(),decision='accept')=>(await db.query("select public.intelkb_review_commit($1,$2,$3,'','{}',$4) as v",[id,JSON.stringify(items),decision,JSON.stringify(choices)])).rows[0].v;
  const item=row=>({id:row.id,revision:row.revision,kind:'seeds'});
  const firstReceipt=receipt(),first=await commit(seeds.slice(0,2).map(item),[],firstReceipt);
  assert.equal(first.ok,2);assert.ok(first.undo_available);
  assert.equal((await commit(seeds.slice(0,2).map(item),[],firstReceipt)).action_id,first.action_id);
  let live=(await db.query("select * from public.intelkb_dictionary where status='approved'")).rows;
  assert.equal(live.find(row=>row.category==='profanity').auto_direct,true);
  assert.equal(live.find(row=>row.category==='chat').auto_gentle,true);
  assert.ok(live.every(row=>row.auto_replace));
  // Existing winner remains the default when another interpretation is approved.
  const second=await commit([item(seeds[2])]);assert.equal(second.ok,1);
  const changedDefault=(await db.query('select public.intelkb_set_style_defaults($1,$2,$3,$4) as v',[receipt(),'ZZ',seeds[2].id,seeds[1].id])).rows[0].v;
  assert.equal((await db.query("select id from public.intelkb_dictionary where auto_direct")).rows[0].id,seeds[2].id);
  await assert.rejects(db.query('select public.intelkb_undo_review($1)',[first.action_id]),/changed/);
  await db.query('select public.intelkb_undo_review($1)',[changedDefault.action_id]);
  assert.equal((await db.query("select id from public.intelkb_dictionary where auto_direct")).rows[0].id,seeds[0].id);
  await db.query('select public.intelkb_undo_review($1)',[changedDefault.action_id]);

  // Renaming an existing default into another group cannot violate mode uniqueness.
  await db.exec('reset role');
  const prior=(await db.query('select * from public.intelkb_dictionary where id=$1',[seeds[0].id])).rows[0];
  const destination=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,status,auto_direct,auto_replace) values('bb','tục khác','profanity','approved',true,true) returning *")).rows[0];
  await db.exec('set role anon');
  const rename=(await db.query("select public.intelkb_submit_proposal($1,'edit','bb',$2,'profanity',true,$3,$4) as v",[receipt(),prior.expansion,prior.id,prior.revision])).rows[0].v;
  await db.exec('set role authenticated');
  const moved=await commit([{id:rename.id,kind:'proposals'}]);assert.equal(moved.ok,1);
  assert.equal((await db.query("select count(*)::int as n from public.intelkb_dictionary where trigger='bb' and auto_direct and status='approved'")).rows[0].n,1);
  await db.query('select public.intelkb_undo_review($1)',[moved.action_id]);
  assert.equal((await db.query('select trigger from public.intelkb_dictionary where id=$1',[prior.id])).rows[0].trigger,'zz');

  // Undoing a rejection must not silently rebase an already stale proposal.
  await db.exec('reset role');
  const now=(await db.query('select * from public.intelkb_dictionary where id=$1',[seeds[0].id])).rows[0];
  const stale=(await db.query("insert into public.intelkb_proposals(receipt,action,target_id,base_revision,trigger,expansion,category) values($1,'edit',$2,$3,'zz','nghĩa từ phiên bản cũ','profanity') returning *",[receipt(),now.id,now.revision-1])).rows[0];
  await db.exec('set role authenticated');
  const staleReject=await commit([{id:stale.id,kind:'proposals'}],[],receipt(),'reject');
  await db.query('select public.intelkb_undo_review($1)',[staleReject.action_id]);
  assert.equal((await db.query('select base_revision from public.intelkb_proposals where id=$1',[stale.id])).rows[0].base_revision,stale.base_revision);
  const staleAccept=await commit([{id:stale.id,kind:'proposals'}]);assert.equal(staleAccept.failed,1);
  await db.exec('set role anon');
  const valid=(await db.query("select public.intelkb_submit_proposal($1,'edit','zz','nghĩa hợp lệ mới','profanity',true,$2,$3) as v",[receipt(),now.id,now.revision])).rows[0].v;
  await db.exec('set role authenticated');
  const mixed=await commit([{id:valid.id,kind:'proposals'},{id:stale.id,kind:'proposals'}]);assert.equal(mixed.ok,1);assert.equal(mixed.failed,1);
  await db.query('select public.intelkb_undo_review($1)',[mixed.action_id]);
  assert.equal((await db.query('select base_revision from public.intelkb_proposals where id=$1',[stale.id])).rows[0].base_revision,stale.base_revision);
  assert.equal((await commit([{id:valid.id,kind:'proposals'}])).ok,1);

  // A fresh multi-meaning mode cannot be approved without an explicit owner choice.
  await db.exec('reset role');
  const fresh=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,source) values('aa','một','chat','bootstrap'),('aa','hai','euphemism','bootstrap') returning *")).rows;
  await db.exec('set role authenticated');
  await assert.rejects(commit(fresh.map(item)),/Choose/);
  const selected=await commit(fresh.map(item),[{trigger:'aa',mode:'gentle',kind:'seeds',id:fresh[1].id}]);
  assert.equal(selected.ok,2);
  live=(await db.query("select * from public.intelkb_dictionary where trigger='aa'")).rows;
  assert.ok(live.find(row=>row.id===fresh[1].id).auto_direct);
  assert.ok(live.find(row=>row.id===fresh[1].id).auto_gentle);
  await db.query('select public.intelkb_undo_review($1)',[selected.action_id]);
  assert.ok((await db.query("select * from public.intelkb_dictionary where trigger='aa'")).rows.every(row=>row.status==='draft'&&row.revision>1));
  // Rejection can also be undone, retaining pending entries and newer revisions.
  const current=(await db.query("select * from public.intelkb_dictionary where trigger='aa'")).rows;
  const rejected=await commit(current.map(item),[],receipt(),'reject');
  await db.query('select public.intelkb_undo_review($1)',[rejected.action_id]);
  assert.ok((await db.query("select status from public.intelkb_dictionary where trigger='aa'")).rows.every(row=>row.status==='draft'));
  // Newly published proposals are unpublished on undo; no rows are permanently deleted.
  await db.exec('set role anon');
  const proposal=(await db.query("select public.intelkb_submit_proposal($1,'new','newalias','nghĩa mới','chat',true) as v",[receipt()])).rows[0].v;
  await assert.rejects(db.query('select * from public.intelkb_review_actions'),/permission denied/);
  await assert.rejects(db.query('select public.intelkb_undo_review($1)',[first.action_id]),/permission denied/);
  await assert.rejects(db.query("select public.intelkb_review_context('[]')"),/permission denied/);
  await db.exec('set role authenticated');
  const approved=await commit([{id:proposal.id,kind:'proposals'}]);
  await db.query('select public.intelkb_undo_review($1)',[approved.action_id]);
  assert.equal((await db.query('select status from public.intelkb_proposals where id=$1',[proposal.id])).rows[0].status,'pending');
  assert.equal((await db.query("select count(*)::int as n from public.intelkb_dictionary where trigger='newalias' and status='approved'")).rows[0].n,0);
  await db.exec('reset role');
  const solo=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,source) values('solo','nghĩa chọn trước','profanity','bootstrap') returning *")).rows[0];
  await db.exec('set role authenticated');
  await commit([item(solo)],[{trigger:'solo',mode:'direct',kind:'seeds',id:solo.id}]);
  assert.equal((await db.query('select auto_replace from public.intelkb_dictionary where id=$1',[solo.id])).rows[0].auto_replace,true);
  await assert.rejects(db.query("select public.intelkb_review_snapshot('{}','{}')"),/permission denied/);
  await db.query("select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000099',false)");
  assert.equal((await db.query('select * from public.intelkb_review_actions')).rows.length,0);
  await assert.rejects(db.query('select public.intelkb_last_review()'),/Administrator required/);
  await assert.rejects(db.query('select public.intelkb_undo_review($1)',[first.action_id]),/Administrator required/);

 }finally{await db.close();}
});
