import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';

test('PostgreSQL enforces anonymous submissions, private moderation, atomic approval and stale-edit rejection',async()=>{
  const db=new PGlite();
  const owner='10000000-0000-4000-8000-000000000001',other='10000000-0000-4000-8000-000000000002';
  try {
    await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
      grant usage on schema public,auth to anon,authenticated;`);
    await db.exec(fs.readFileSync(new URL('../../supabase/migrations/20261017_community_moderation.sql',import.meta.url),'utf8'));
    await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[owner,'owner@test.invalid',other,'other@test.invalid']);
    await db.query('insert into public.intelkb_admins(user_id) values($1)',[owner]);
    async function as(role,id='') {await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec(`set role ${role}`);}
    const submit=async(action='new',target=null,revision=null,expansion='nghĩa mới')=>(await db.query("select public.intelkb_submit_proposal(gen_random_uuid(),$1,'abc',$2,'chat',false,$3,$4,'ví dụ','') as result",[action,expansion,target,revision])).rows[0].result;
    await as('anon');
    const p=await submit();assert.equal(p.status,'pending');
    assert.equal((await db.query('select id from public.intelkb_dictionary')).rows.length,0);
    await assert.rejects(db.query('select * from public.intelkb_proposals'),/permission denied/);
    await assert.rejects(db.query("update public.intelkb_proposals set status='accepted' where id=$1",[p.id]),/permission denied/);
    await assert.rejects(db.query("insert into public.intelkb_dictionary(trigger,expansion,category,status) values('hack','bypass','chat','approved')"),/permission denied/);
    await assert.rejects(db.query("select public.intelkb_review_proposal($1,'accept')",[p.id]),/permission denied/);
    await as('authenticated',other);
    assert.equal((await db.query('select public.intelkb_is_admin() as allowed')).rows[0].allowed,false);
    assert.equal((await db.query('select id from public.intelkb_proposals')).rows.length,0);
    await assert.rejects(db.query("select public.intelkb_review_proposal($1,'accept')",[p.id]),/Administrator required/);
    await assert.rejects(db.query('insert into public.intelkb_admins(user_id) values($1)',[other]),/permission denied/);
    await assert.rejects(db.query("select public.intelkb_review_seed($1,'accept',1)",[p.id]),/Administrator required/);
    await as('authenticated',owner);
    const accepted=(await db.query("select public.intelkb_review_proposal($1,'accept','correct') as result",[p.id])).rows[0].result;
    assert.ok(accepted.entry_id);
    await assert.rejects(db.query("select public.intelkb_review_proposal($1,'accept')",[p.id]),/already processed/);
    await as('anon');
    assert.equal((await db.query('select trigger,expansion from public.intelkb_dictionary')).rows[0].expansion,'nghĩa mới');
    await assert.rejects(db.query('select reviewed_by from public.intelkb_dictionary'),/permission denied/);
    const editA=await submit('edit',accepted.entry_id,1,'nghĩa sửa A'),editB=await submit('edit',accepted.entry_id,1,'nghĩa sửa B');
    await assert.rejects(submit('edit',accepted.entry_id,999,'stale'),/changed/);
    await as('authenticated',owner);
    await db.query("select public.intelkb_review_proposal($1,'accept')",[editA.id]);
    await assert.rejects(db.query("select public.intelkb_review_proposal($1,'accept')",[editB.id]),/changed since proposal/);
    assert.equal((await db.query('select status from public.intelkb_proposals where id=$1',[editB.id])).rows[0].status,'pending');
    await db.query("select public.intelkb_review_proposal($1,'reject','old version')",[editB.id]);
    assert.equal((await db.query('select expansion,revision from public.intelkb_dictionary where id=$1',[accepted.entry_id])).rows[0].revision,2);
    await db.exec('reset role');
    await db.exec(fs.readFileSync(new URL('../../supabase/seeds/initial_dictionary.sql',import.meta.url),'utf8'));
    assert.equal(Number((await db.query("select count(*) as n from public.intelkb_dictionary where status='draft'")).rows[0].n),419);
    await as('anon');assert.equal((await db.query('select id from public.intelkb_dictionary')).rows.length,1);
    await as('authenticated',owner);
    const seed=(await db.query("select id,revision from public.intelkb_dictionary where status='draft' limit 1")).rows[0];
    await db.query("select public.intelkb_review_seed($1,'accept',$2)",[seed.id,seed.revision]);
    await as('anon');assert.equal((await db.query('select id from public.intelkb_dictionary')).rows.length,2);
  } finally {await db.close();}
});
