import test from 'node:test';
import assert from 'node:assert/strict';
import {reviewTargets} from '../dist/review-actions.mjs';
test('row actions apply to the selection only from a selected eligible row',()=>{
  const rows=[{id:'a',status:'draft'},{id:'b',status:'pending'},{id:'c',status:'draft'},{id:'d',status:'approved'}];
  const selected=new Set(['a','b','d','outside-page']);
  assert.deepEqual(reviewTargets(rows,selected,'a').map(row=>row.id),['a','b']);
  assert.deepEqual(reviewTargets(rows,selected,'b').map(row=>row.id),['a','b']);
  assert.deepEqual(reviewTargets(rows,selected,'c').map(row=>row.id),['c']);
  assert.deepEqual(reviewTargets(rows,selected,'d'),[]);
  assert.deepEqual(reviewTargets(rows,selected,'missing'),[]);
});
