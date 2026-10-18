import test from 'node:test';
import assert from 'node:assert/strict';
import {findPair,findTriggerMatches,parseContributions,groupReviewRows} from '../dist/contribution-tools.mjs';

test('typing lookup counts unique meanings, ranks exact then prefix and updates for unfinished aliases',()=>{
  const rows=[{trigger:'axl',expansion:'contains'},{trigger:'xla',expansion:'prefix'},{trigger:'xl',expansion:'xin lỗi'},{trigger:'XL',expansion:'XIN LỖI'},{trigger:'xl',expansion:'xạo lồn'},{trigger:'má',expansion:'mẹ'}];
  assert.deepEqual(findTriggerMatches(rows,''),{query:'',exact:0,total:0,rows:[]});
  const partial=findTriggerMatches(rows,' X ',2);
  assert.equal(partial.exact,0);assert.equal(partial.total,4);assert.equal(partial.rows.length,2);
  const full=findTriggerMatches(rows,'XL');
  assert.equal(full.exact,2);assert.equal(full.total,4);assert.ok(full.rows.slice(0,2).every(row=>row.trigger.toLowerCase()==='xl'));
  assert.equal(full.rows[2].trigger,'xla');assert.equal(full.rows[3].trigger,'axl');
  assert.equal(findTriggerMatches(rows,'unknown').total,0);
  assert.equal(findTriggerMatches(rows,'ma').total,0);
  assert.equal(findTriggerMatches(rows,'MÁ'.normalize('NFD')).exact,1);
});
test('duplicate check requires both fields, ignores case/spacing/Unicode but preserves Vietnamese accents',()=>{
  const rows=[{id:'1',trigger:'XL',expansion:'Xin lỗi'},{id:'2',trigger:'ma',expansion:'mẹ'}];
  assert.equal(findPair(rows,{trigger:' xl ',expansion:'xin  lỗi'.normalize('NFD')}).id,'1');
  assert.equal(findPair(rows,{trigger:'xl',expansion:'xạo lồn'}),null);
  assert.equal(findPair(rows,{trigger:'má',expansion:'mẹ'}),null);
  assert.equal(findPair(rows,{trigger:'xl',expansion:'xin lỗi'},'1'),null);
});
test('paste parser accepts Excel, CSV quoted fields, headers and arrow notation',()=>{
  assert.equal(parseContributions('trigger,expansion\nabc,"nghĩa, có dấu phẩy"')[0].value.expansion,'nghĩa, có dấu phẩy');
  assert.equal(parseContributions('abc\tnghĩa mới\nxyz\tnghĩa thứ hai').length,2);
  assert.equal(parseContributions('abc → nghĩa mới')[0].value.trigger,'abc');
  assert.equal(parseContributions('abc,"hai\ndòng"')[0].value.expansion,'hai dòng');
});
test('paste parser reports duplicates and invalid lines without losing valid contributions',()=>{
  const rows=parseContributions('abc → nghĩa mới\nABC → NGHĨA MỚI\nx → x\nxyz → khác');
  assert.equal(rows.filter(row=>!row.error).length,2);assert.match(rows[1].error,/Trùng/);assert.ok(rows[2].error);
  assert.ok(parseContributions('abc → nghĩa mới',[{trigger:'ABC',expansion:'nghĩa mới'}])[0].error);
  assert.ok(parseContributions(Array.from({length:21},(_,i)=>`x${i} → nghĩa`).join('\n'))[0].error);
});
test('group review only groups supplied page rows, case-insensitively',()=>{
  const rows=[{trigger:'xl',id:1},{trigger:'XL',id:2},{trigger:'ms',id:3}];
  assert.deepEqual(groupReviewRows(rows).map(([key,group])=>[key,group.length]),[['xl',2],['ms',1]]);
});
