import test from 'node:test';
import assert from 'node:assert/strict';
import {reviewTargets,entryDiff,nextAfterReview} from '../dist/review-actions.mjs';
test('row actions apply to the selection only from a selected eligible row',()=>{
  const rows=[{id:'a',status:'draft'},{id:'b',status:'pending'},{id:'c',status:'draft'},{id:'d',status:'approved'}];
  const selected=new Set(['a','b','d','outside-page']);
  assert.deepEqual(reviewTargets(rows,selected,'a').map(row=>row.id),['a','b']);
  assert.deepEqual(reviewTargets(rows,selected,'b').map(row=>row.id),['a','b']);
  assert.deepEqual(reviewTargets(rows,selected,'c').map(row=>row.id),['c']);
  assert.deepEqual(reviewTargets(rows,selected,'d'),[]);
  assert.deepEqual(reviewTargets(rows,selected,'missing'),[]);
});
test('diffs show every changed vocabulary field and navigation skips a reviewed group',()=>{
  const before={trigger:'a',expansion:'anh',category:'chat',auto_replace:false};
  assert.deepEqual(entryDiff(before,{...before,expansion:'em',auto_replace:true}).map(change=>change.key),['expansion','auto_replace']);
  const rows=['a','b','c','d'].map(id=>({id}));
  assert.equal(nextAfterReview(rows,new Set(['a','b'])),'c');
  assert.equal(nextAfterReview(rows,new Set(['d'])),'a');
  assert.equal(nextAfterReview(rows,new Set(['a','b','c','d'])),null);
});
