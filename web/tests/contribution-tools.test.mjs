import test from 'node:test';
import assert from 'node:assert/strict';
import {findPair,parseContributions,groupReviewRows} from '../dist/contribution-tools.mjs';
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
