import test from 'node:test';
import assert from 'node:assert/strict';
import {CommunityStore} from '../dist/community-store.mjs';
const config={url:'https://example.invalid',publishableKey:'public-test',table:'unused'};
const storage=()=>{const m=new Map();return {getItem:k=>m.get(k)||null,setItem:(k,v)=>m.set(k,v),removeItem:k=>m.delete(k)};};
const word={trigger:'abc',expansion:'một nghĩa mới',category:'chat',auto_replace:false};

test('concurrent admin requests share one token refresh and logout cannot be undone by its response',async()=>{
 let resolveRefresh,calls=0;
 const store=new CommunityStore({storage:storage(),config,fetcher:async()=>{calls++;return new Promise(resolve=>{resolveRefresh=()=>resolve(new Response(JSON.stringify({user:{id:'owner'},access_token:'new',refresh_token:'rotated',expires_in:3600})));});}});
 store.setSession({user:{id:'owner'},access_token:'old',refresh_token:'old-refresh',expires_at:1});
 const pending=[store.accessToken(),store.accessToken(),store.accessToken()];assert.equal(calls,1);
 resolveRefresh();assert.deepEqual(await Promise.all(pending),['new','new','new']);assert.equal(store.syncing,null);
 store.setSession({user:{id:'owner'},access_token:'old',refresh_token:'old-refresh',expires_at:1});
 const loggedOut=store.accessToken();store.session=null;resolveRefresh();
 await assert.rejects(loggedOut,/đã kết thúc/);assert.equal(store.session,null);
});

test('saving a published entry uses an authenticated RPC and passes the original revision',async()=>{
 let call;
 const store=new CommunityStore({storage:storage(),config,fetcher:async(url,options)=>{call={url,options};return new Response('{}');}});
 const row={id:'published',revision:9,status:'approved'};
 await assert.rejects(store.savePublished(row,word),/Đăng nhập/);
 store.setSession({user:{id:'owner'},access_token:'owner-token',expires_at:9999999999});
 await store.savePublished(row,word,'note','receipt');
 assert.ok(call.url.endsWith('/rpc/intelkb_save_published'));assert.equal(call.options.headers.Authorization,'Bearer owner-token');
 const body=JSON.parse(call.options.body);assert.equal(body.p_revision,9);assert.equal(body.p_id,'published');assert.deepEqual(body.p_entry,word);
 await assert.rejects(store.savePublished({...row,status:'pending'},word),/đã công bố/);
});

test('RPC failures retain status, SQL code, details and hint for diagnosis',async()=>{
 const store=new CommunityStore({storage:storage(),config,fetcher:async()=>new Response(JSON.stringify({code:'42702',message:'ambiguous column',details:'column id',hint:'qualify it'}),{status:400})});
 await assert.rejects(store.request('/rest/v1/rpc/intelkb_review_commit'),error=>error.status===400&&error.code==='42702'&&error.details==='column id'&&error.hint==='qualify it'&&error.message==='ambiguous column');
});
test('anonymous contributions use only the submission RPC and cannot set moderation fields',async()=>{
  let call;
  const store=new CommunityStore({storage:storage(),config,fetcher:async(url,options)=>{call={url,options};return new Response(JSON.stringify({id:'proposal-id',status:'pending'}));}});
  const result=await store.submit({...word,status:'accepted',moderated_by:'attacker'});
  assert.equal(result.status,'pending');assert.ok(call.url.endsWith('/rpc/intelkb_submit_proposal'));
  assert.equal(call.options.headers.Authorization,undefined);
  const body=JSON.parse(call.options.body);assert.equal(body.p_action,'new');assert.equal(body.status,undefined);assert.equal(body.moderated_by,undefined);
  assert.equal(store.drafts.length,0);assert.equal(store.cachedCatalogue(),null);
});
test('failed submission persists a retry receipt and never becomes a published word',async()=>{
  const store=new CommunityStore({storage:storage(),config,fetcher:async()=>{throw new Error('offline');}});
  await assert.rejects(store.submit(word),/offline/);assert.equal(store.drafts.length,1);const receipt=store.drafts[0].receipt;
  await assert.rejects(store.submit(word,{receipt}),/offline/);assert.equal(store.drafts.length,1);assert.equal(store.cachedCatalogue(),null);
});
test('public catalogue omits the admin token even when signed in',async()=>{
  let header,url;
  const store=new CommunityStore({storage:storage(),config,fetcher:async(u,o)=>{header=o.headers;url=u;return new Response('[]');}});
  store.setSession({user:{id:'owner'},access_token:'owner-token',expires_at:9999999999});
  await store.loadCatalogue();assert.equal(header.Authorization,undefined);assert.ok(url.includes('status=eq.approved'));
});
test('HTTP transport binds native fetch to its global receiver for browser compatibility',async()=>{
  const store=new CommunityStore({storage:storage(),config,fetcher:function(){assert.equal(this,globalThis);return Promise.resolve(new Response('[]'));}});
  await store.loadCatalogue();
});
test('edit proposals carry target revision and reject missing targets before sending',async()=>{
  let body;
  const store=new CommunityStore({storage:storage(),config,fetcher:async(u,o)=>{body=JSON.parse(o.body);return new Response('{"id":"id","status":"pending"}');}});
  await assert.rejects(store.submit(word,{action:'edit'}),/đã công bố/);
  await store.submit(word,{action:'edit',target:{id:'target',revision:3},explanation:'sửa cho đúng'});
  assert.equal(body.p_target_id,'target');assert.equal(body.p_base_revision,3);assert.equal(body.p_explanation,'sửa cho đúng');
});
test('admin review requires a user session and a server RPC',async()=>{
  let call;
  const store=new CommunityStore({storage:storage(),config,fetcher:async(url,options)=>{call={url,options};return new Response('{}');}});
  await assert.rejects(store.review({id:'x'},'proposals','accept','',word),/Đăng nhập/);
  store.setSession({user:{id:'owner'},access_token:'owner-token',expires_at:9999999999});
  await store.review({id:'x'},'proposals','accept','đã kiểm tra',word);
  assert.ok(call.url.endsWith('/rpc/intelkb_review_proposal'));assert.equal(call.options.headers.Authorization,'Bearer owner-token');
});
