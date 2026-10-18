import test from 'node:test';
import assert from 'node:assert/strict';
import {publicCatalogue,filterCatalogue,keyboardDictionary,catalogueStats} from '../dist/catalogue.mjs';
import {makeIndex,expandText,suggestionsFor} from '../dist/engine.mjs';
import fs from 'node:fs';
const samples=[{trigger:'ms',expansion:'mới',category:'chat'},{trigger:'xl',expansion:'xin lỗi',category:'chat'}];
test('public metrics separate bundled provenance from approved community meanings',()=>{
 const rows=publicCatalogue(samples,[{id:'a',trigger:'MS',expansion:'mới',category:'chat',source:'bootstrap',status:'approved'},
 {id:'b',trigger:'ms',expansion:'một nghĩa khác',category:'chat',source:'community',status:'approved'}]);
 assert.deepEqual(catalogueStats(rows),{total:3,bundled:2,community:1,triggers:2});
 assert.deepEqual(catalogueStats([]),{total:0,bundled:0,community:0,triggers:0});
});
test('built-in words are included in the approved catalogue without impersonating database rows',()=>{
  const rows=publicCatalogue(samples,[]);
  assert.equal(rows.length,2);assert.ok(rows.every(r=>r.sample && r.status===undefined));
  assert.equal(filterCatalogue(rows,{status:"approved"}).length,2);
  assert.equal(filterCatalogue(rows,{status:"community"}).length,0);
});
test('published meanings replace matching samples without losing other meanings or leaking private drafts',()=>{
  const rows=publicCatalogue(samples,[{id:'approved',trigger:'MS',expansion:'mới',category:'chat',status:'approved'},
    {id:'draft',trigger:'private',expansion:'private draft',status:'draft'}]);
  assert.equal(rows.length,2);assert.equal(rows.find(r=>r.trigger==='MS').sample,false);
  assert.equal(rows.find(r=>r.trigger==='MS').id,'approved');
  assert.equal(filterCatalogue(rows,{status:'approved'}).length,2);
  assert.equal(filterCatalogue(rows,{status:'community'}).length,1);
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
  assert.equal(visible.length,1);assert.equal(visible.find(row=>!row.sample).id,'current');
  const keyboard=keyboardDictionary(duplicates,remote);
  assert.equal(keyboard.length,1);assert.equal(keyboard[0].id,'current');
  const index=makeIndex(duplicates);
  assert.equal(index.get('ms').length,2);
  assert.equal(suggestionsFor('ms',2,index,'direct').length,2);
});
const bundled=JSON.parse(fs.readFileSync(new URL('../dist/words.json',import.meta.url)));

test('editing a published meaning never resurrects its old bundled wording or metadata',()=>{
 const base=[{trigger:'chs',expansion:'chẳng hiểu sao',category:'chat'}];
 const live=[{id:'changed',trigger:'chs',expansion:'chả hiểu sao',category:'chat',source:'bootstrap',status:'approved',auto_replace:false,revision:3}];
 const rows=publicCatalogue(base,live);
 assert.equal(rows.length,1);assert.equal(rows[0].expansion,'chả hiểu sao');assert.equal(rows[0].auto_replace,false);
 assert.equal(filterCatalogue(rows,{status:'sample'}).length,1);assert.equal(filterCatalogue(rows,{status:'community'}).length,0);
 assert.equal(rows[0].sample,false);
});

test('catalogue filters automatic filling independently of approval and category',()=>{
  const rows=publicCatalogue([{trigger:'ae',expansion:'anh em',category:'chat',auto_replace:true}],
    [{id:'b',trigger:'b',expansion:'bạn',category:'chat',status:'approved',auto_replace:false}]);
  assert.deepEqual(filterCatalogue(rows,{auto:'on'}).map(row=>row.trigger),['ae']);
  assert.deepEqual(filterCatalogue(rows,{auto:'off',status:'approved'}).map(row=>row.trigger),['b']);
  assert.equal(filterCatalogue(rows,{auto:'on',status:'approved'}).length,1);
  assert.equal(filterCatalogue(rows,{auto:'on',status:'community'}).length,0);
  const defaults=publicCatalogue(bundled,[]);
  assert.equal(defaults.find(row=>row.trigger==='hnay').auto_replace,true);
  assert.equal(defaults.find(row=>row.trigger==='xl').auto_replace,true);
  assert.ok(defaults.find(row=>row.trigger==='xl'&&row.category==='profanity').auto_direct);
  assert.ok(defaults.find(row=>row.trigger==='xl'&&row.category==='chat').auto_gentle);
});
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
