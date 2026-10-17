import test from 'node:test';
import assert from 'node:assert/strict';
import {publicCatalogue,filterCatalogue} from '../dist/catalogue.mjs';
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
