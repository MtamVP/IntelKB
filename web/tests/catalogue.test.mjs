import test from 'node:test';
import assert from 'node:assert/strict';
import {publicCatalogue,filterCatalogue,keyboardDictionary} from '../dist/catalogue.mjs';
import {makeIndex,expandText,suggestionsFor} from '../dist/engine.mjs';
import fs from 'node:fs';
const samples=[{trigger:'ms',expansion:'mới',category:'chat'},{trigger:'xl',expansion:'xin lỗi',category:'chat'}];
test('public reference list remains browsable before seeds are approved',()=>{
  const rows=publicCatalogue(samples,[]);
  assert.equal(rows.length,2);assert.ok(rows.every(r=>r.sample));
});
test('published meanings replace matching samples without losing other meanings or leaking private drafts',()=>{
  const rows=publicCatalogue(samples,[{id:'approved',trigger:'MS',expansion:'mới',category:'chat',status:'approved'},
    {id:'draft',trigger:'private',expansion:'private draft',status:'draft'}]);
  assert.equal(rows.length,2);assert.equal(rows.find(r=>r.trigger==='MS').sample,false);
  assert.equal(rows.find(r=>r.trigger==='MS').id,'approved');
  assert.equal(filterCatalogue(rows,{status:'approved'}).length,1);
  assert.equal(filterCatalogue(rows,{status:'sample'}).length,1);
});
test('dictionary search supports unaccented Vietnamese and combined category/status filters',()=>{
  const rows=publicCatalogue(samples,[]);
  assert.equal(filterCatalogue(rows,{query:'xin loi',category:'chat',status:'sample'})[0].trigger,'xl');
  assert.equal(filterCatalogue(rows,{query:'xin loi',category:'game'}).length,0);
});
test('duplicate pairs differing only in case, whitespace or Unicode appear once across both sources',()=>{
  const duplicates=[{trigger:' MS ',expansion:' mới ',category:'chat'},
    {trigger:'ms',expansion:'mới'.normalize('NFD'),category:'chat'},
    {trigger:'ms',expansion:'một nghĩa khác',category:'chat'}];
  const remote=[{id:'old',trigger:'ms',expansion:'mới',status:'approved',revision:1,auto_replace:true},
    {id:'current',trigger:'MS',expansion:'  mới ',status:'approved',revision:2,auto_replace:false}];
  const visible=publicCatalogue(duplicates,remote);
  assert.equal(visible.length,2);assert.equal(visible.find(row=>!row.sample).id,'current');
  const keyboard=keyboardDictionary(duplicates,remote);
  assert.equal(keyboard.length,1);assert.equal(keyboard[0].id,'current');
  const index=makeIndex(duplicates);
  assert.equal(index.get('ms').length,2);
  assert.equal(suggestionsFor('ms',2,index,'direct').length,2);
});
const bundled=JSON.parse(fs.readFileSync(new URL('../dist/words.json',import.meta.url)));
test('successful empty Supabase response keeps broad keyboard suggestions and autocomplete working',()=>{
  const rows=keyboardDictionary(bundled,[]),index=makeIndex(rows);
  assert.equal(rows.length,bundled.length);
  const text='hnay ms dc k, nhg nhiu thui';
  assert.equal(expandText(text,text.length,index,'direct',true).text,'hôm nay mới được không, nhưng nhiều thôi');
  assert.equal(suggestionsFor('xl',2,index,'direct').length,2);
});
test('partial moderation overrides an entire trigger without disabling unrelated demo words',()=>{
  const rows=keyboardDictionary(bundled,[
    {trigger:'HNAY',expansion:'hôm nay',status:'approved',auto_replace:false,category:'chat'},
    {trigger:'xl',expansion:'xin lỗi',status:'approved',auto_replace:false,category:'chat'},
    {trigger:'newword',expansion:'từ cộng đồng',status:'approved',auto_replace:true,category:'chat'},
    {trigger:'pendingword',expansion:'chưa duyệt',status:'pending',auto_replace:true},
    {trigger:'privateword',expansion:'riêng tư',status:'draft',auto_replace:true}
  ]),index=makeIndex(rows);
  const text='hnay ms dc k newword pendingword privateword';
  assert.equal(expandText(text,text.length,index,'direct',true).text,'hnay mới được không từ cộng đồng pendingword privateword');
  assert.deepEqual(suggestionsFor('xl',2,index,'direct').map(row=>row.expansion),['xin lỗi']);
  assert.equal(rows.find(row=>row.trigger==='ms').demo,true);
  assert.equal(rows.find(row=>row.trigger==='newword').demo,false);
});
