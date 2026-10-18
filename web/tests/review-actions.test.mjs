import test from 'node:test';
import assert from 'node:assert/strict';
import {reviewTargets,entryDiff,nextAfterReview,reviewError,makeReviewDraft,dirtyReviewDraft,staleReviewDraft} from '../dist/review-actions.mjs';

test('review drafts retain their original version and cannot silently overwrite refreshed data',()=>{
 const row={id:'a',trigger:'ms',expansion:'mới',category:'chat',status:'approved',revision:1,auto_replace:true};
 const unchanged=makeReviewDraft(row,{...row,note:''});assert.equal(dirtyReviewDraft(unchanged),false);
 const draft=makeReviewDraft(row,{...row,expansion:'một nghĩa sửa',note:''});
 assert.ok(dirtyReviewDraft(draft));assert.equal(staleReviewDraft(row,draft),false);
 const fresh={...row,revision:2,auto_replace:false};assert.equal(staleReviewDraft(fresh,draft),true);
 const continued=makeReviewDraft(fresh,{...draft,expansion:'tiếp tục sửa'},draft);
 assert.equal(continued._base,draft._base);assert.equal(staleReviewDraft(fresh,continued),true);
 const reset=makeReviewDraft(fresh,{...fresh,note:''});assert.equal(dirtyReviewDraft(reset),false);assert.equal(staleReviewDraft(fresh,reset),false);
 const proposal={...row,revision:undefined,status:'pending',base_revision:1};
 const proposalDraft=makeReviewDraft(proposal,{...proposal,expansion:'đã sửa',note:''});
 assert.equal(staleReviewDraft({...proposal,status:'accepted'},proposalDraft),true);
});

test('review errors identify the required meaning choice and preserve database diagnostics',()=>{
 const missing=reviewError(new Error('Choose gentle default for tt'));
 assert.equal(missing.needsChoice,true);assert.match(missing.message,/“tt”.*nhắn nhẹ/);
 assert.equal(reviewError(new Error('Default must be an approved or successfully reviewed entry')).needsChoice,true);
 const database=reviewError(Object.assign(new Error('ambiguous column'),{code:'42702',details:'column id',hint:'qualify it'}));
 assert.equal(database.needsChoice,false);assert.match(database.message,/42702.*column id.*qualify it/);
 assert.equal(reviewError(new Error('network timeout')).needsChoice,false);
});
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
