import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {referenceApprovalSql} from '../reference-approval.mjs';
import {publicCatalogue} from '../dist/catalogue.mjs';
import {makeIndex,expandText} from '../dist/engine.mjs';

test('bundled approval is repeatable, keeps autocomplete defaults and preserves moderation decisions',async()=>{
 const db=new PGlite();
 try {
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);
   create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;`);
  for(const name of ['20261017_community_moderation.sql','20261018_review_tools.sql','20261018_entry_changes.sql','20261018_style_review.sql'])await db.exec(fs.readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
  await db.exec(fs.readFileSync(new URL('../../supabase/seeds/initial_dictionary.sql',import.meta.url),'utf8'));
  const words=JSON.parse(fs.readFileSync(new URL('../dist/words.json',import.meta.url)));
  await db.exec(`update public.intelkb_dictionary set status='rejected' where trigger='asap';
   update public.intelkb_dictionary set revision=2 where trigger='b';
   insert into public.intelkb_dictionary(trigger,expansion,category,status,auto_replace) values('bb','owner meaning','chat','approved',false);
   insert into public.intelkb_dictionary(trigger,expansion,category,status,auto_replace) values('nch','owner meaning','chat','approved',true);
   insert into public.intelkb_dictionary(trigger,expansion,category,status,auto_replace) values('HS','học sinh','chat','approved',false);
   insert into public.intelkb_dictionary(trigger,expansion,category) values('zzz','user draft','chat');
   insert into public.intelkb_proposals(receipt,action,trigger,expansion,category) values(gen_random_uuid(),'new','zzz','user proposal','chat');`);
  const sql=referenceApprovalSql(words);await db.exec(sql);
  const snapshot=(await db.query('select * from public.intelkb_dictionary order by id')).rows;
  await db.exec(sql);assert.deepEqual((await db.query('select * from public.intelkb_dictionary order by id')).rows,snapshot);
  assert.equal(snapshot.find(row=>row.trigger==='asap').status,'rejected');
  assert.equal(snapshot.find(row=>row.trigger==='b').status,'draft');
  assert.ok(snapshot.filter(row=>row.trigger==='bb'&&row.source==='bootstrap').every(row=>row.status==='approved'&&!row.auto_replace));
  assert.equal(snapshot.find(row=>row.trigger==='bb'&&row.source==='community').auto_replace,false);
  assert.equal(snapshot.filter(row=>row.trigger.toLowerCase()==='hs').length,1);
  const archive=(await db.query('select * from public.intelkb_bootstrap_archive')).rows;
  assert.equal(archive.length,1);assert.equal(archive[0].original_row.trigger,'hs');assert.equal(archive[0].original_row.status,'draft');
  await db.exec('set role anon');await assert.rejects(db.query('select * from public.intelkb_bootstrap_archive'),/permission denied/);await db.exec('reset role');
  const preserved=snapshot.find(row=>row.trigger==='nch'&&row.source==='community');assert.ok(preserved.auto_replace&&preserved.auto_direct&&preserved.auto_gentle);
  assert.equal(snapshot.find(row=>row.trigger==='zzz').status,'draft');
  assert.equal((await db.query('select status from public.intelkb_proposals')).rows[0].status,'pending');
  const approved=snapshot.filter(row=>row.status==='approved'),defaults=publicCatalogue(words,[]);
  for(const row of approved.filter(row=>row.source==='bootstrap')){
   if(['bb','nch'].includes(row.trigger))continue;
   const base=defaults.find(base=>base.trigger===row.trigger&&base.expansion===row.expansion);
   assert.equal(row.auto_replace,base.auto_replace);assert.equal(row.auto_direct,base.auto_direct);assert.equal(row.auto_gentle,base.auto_gentle);
  }
  assert.equal(expandText('hnay ms',7,makeIndex(approved),'direct',true).text,'hôm nay mới');
  assert.equal(expandText('xl',2,makeIndex(approved),'gentle',true).text,'xin lỗi');
 } finally {await db.close();}
});
