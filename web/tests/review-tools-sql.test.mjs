import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('review upgrade protects private data, blocks case-insensitive duplicate pairs and reports partial batch failures',async()=>{
  const db=new PGlite(),owner='10000000-0000-4000-8000-000000000001',other='10000000-0000-4000-8000-000000000002';
  try{
    await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
      grant usage on schema public,auth to anon,authenticated;`);
    for(const name of ['20261017_community_moderation.sql','20261018_review_tools.sql'])await db.exec(fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
    // Safe repeated upgrade on an existing installation.
    await db.exec(fs.readFileSync(new URL('../../supabase/migrations/20261018_review_tools.sql',import.meta.url),'utf8'));
    await db.query('insert into auth.users(id) values($1),($2)',[owner,other]);await db.query('insert into public.intelkb_admins values($1)',[owner]);
    const seeds=(await db.query("insert into public.intelkb_dictionary(trigger,expansion,category,source) values('abc','nghĩa thứ nhất','chat','bootstrap'),('abc','nghĩa thứ hai','chat','bootstrap') returning id,revision")).rows;
    async function as(role,id=''){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role '+role);}
    async function check(trigger,expansion){return (await db.query('select public.intelkb_check_pair($1,$2) as value',[trigger,expansion])).rows[0].value;}
    await as('anon');assert.deepEqual(await check('abc','nghĩa thứ nhất'),{match:'none'});
    const receipt='20000000-0000-4000-8000-000000000001';
    const submit=async(trigger,meaning,id)=>(await db.query("select public.intelkb_submit_proposal($1,'new',$2,$3,'chat') as value",[id,trigger,meaning])).rows[0].value;
    const proposal=await submit('abcd','Nghĩa Mới',receipt);
    assert.deepEqual(await check('ABCD','nghĩa  mới'),{match:'pending'});
    await assert.rejects(submit('ABCD','nghĩa mới','20000000-0000-4000-8000-000000000002'),/identical/);
    assert.equal((await submit('abcd','Nghĩa Mới',receipt)).id,proposal.id);
    await assert.rejects(db.query('select public.intelkb_review_queue()'),/permission denied/);
    await assert.rejects(db.query("select public.intelkb_review_batch('[]','accept')"),/permission denied/);
    await as('authenticated',other);await assert.rejects(db.query('select public.intelkb_review_queue()'),/Administrator required/);
    await as('authenticated',owner);
    const queue=(await db.query("select public.intelkb_review_queue('seeds','pending','ABC','chat',0,50,true) as value")).rows[0].value;
    assert.equal(queue.total,2);assert.equal(queue.counts.proposals,1);
    const items=[{id:seeds[0].id,kind:'seeds',revision:1},{id:seeds[1].id,kind:'seeds',revision:99},{id:proposal.id,kind:'proposals'}];
    const result=(await db.query("select public.intelkb_review_batch($1,'accept','checked','{}') as value",[JSON.stringify(items)])).rows[0].value;
    assert.equal(result.ok,2);assert.equal(result.failed,1);assert.equal(result.rows.length,3);
    assert.equal((await db.query('select * from public.intelkb_review_log')).rows.length,2);
    await as('anon');assert.deepEqual(await check('ABCD','nghĩa mới'),{match:'published'});
    await assert.rejects(submit('abcd','nghĩa mới','20000000-0000-4000-8000-000000000003'),/already published/);
    assert.equal((await db.query('select id from public.intelkb_dictionary')).rows.length,2);
    await assert.rejects(db.query('select * from public.intelkb_review_log'),/permission denied/);
    await as('authenticated',owner);
    const rejected=(await db.query("select public.intelkb_review_batch($1,'reject') as value",[JSON.stringify([{id:seeds[1].id,kind:'seeds',revision:1}])])).rows[0].value;
    assert.equal(rejected.ok,1);
    const retry=(await db.query("select public.intelkb_review_batch($1,'accept') as value",[JSON.stringify([items[0]])])).rows[0].value;
    assert.equal(retry.failed,1);
  }finally{await db.close();}
});
