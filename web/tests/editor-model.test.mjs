import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {makeIndex,pendingWords,suggestionsFor,expandText} from '../dist/engine.mjs';
import {EditorModel} from '../dist/editor-model.mjs';
const words=JSON.parse(fs.readFileSync(new URL('../dist/words.json',import.meta.url)));
const dictionary=makeIndex(words);
const create=()=>new EditorModel(dictionary);

test('apology sample explicitly chooses xin lỗi and tôi and undo restores its raw text',()=>{
  const html=fs.readFileSync(new URL('../dist/index.html',import.meta.url),'utf8');
  const sample=html.match(/data-sample="(xl nha t đến muộn)" data-meanings='([^']+)'/);
  assert.ok(sample,'apology button must carry explicit meanings');
  const m=create();m.load(sample[1],JSON.parse(sample[2]));
  assert.equal(m.text,'xin lỗi nha tôi đến muộn');
  assert.equal(m.current.start,m.text.length);
  assert.equal(pendingWords(m.text,m.index,'direct',m.ranges).length,0);
  assert.equal(m.current.report.changes.length,2);
  m.undo();assert.equal(m.text,'xl nha t đến muộn');
  m.redo();assert.equal(m.text,'xin lỗi nha tôi đến muộn');
});
test('ordinary input stays ambiguous and a sample cannot invent an unavailable meaning',()=>{
  const m=create();m.load('xl nha t đến muộn');
  assert.equal(m.text,'xl nha t đến muộn');
  m.load('xl',{xl:'nghĩa chưa được duyệt'});assert.equal(m.text,'xl');
  m.style='gentle';m.load('xl',{xl:'xạo lồn'});assert.equal(m.text,'xl');
});

test('sample and paste conversion includes the last word without a trailing space',()=>{
  const m=create();m.load('hnay dc k');
  assert.equal(m.text,'hôm nay được không');
  assert.equal(m.current.start,m.text.length);
  assert.equal(m.current.report.changes.length,3);
  m.undo();assert.equal(m.text,'hnay dc k');
  m.redo();assert.equal(m.text,'hôm nay được không');
});
test('paste into the middle preserves the insertion caret, suffix, emoji and newlines',()=>{
  const m=create();m.edit('🙂 trước, hnay dc k\nsau',18);
  // Place the caret immediately after the pasted last abbreviation.
  const caret=m.text.indexOf('\n');m.select(caret);m.transform(true);
  assert.equal(m.text,'🙂 trước, hôm nay được không\nsau');
  assert.equal(m.current.start,m.text.indexOf('\n'));
});
test('conversion maps both ends of a noncollapsed selection',()=>{
  const m=create();m.edit('🙂 hnay dc k!',3,10);m.transform(true);
  assert.equal(m.text,'🙂 hôm nay được không!');
  assert.equal(m.text.slice(m.current.start,m.current.end),'hôm nay được');
});
test('choosing one meaning converts other eligible words in the same transaction',()=>{
  const m=create();m.edit('xl hnay dc k',12);
  const chosen=suggestionsFor(m.text,2,m.index,'direct').find(r=>r.expansion==='xin lỗi');
  m.choose(chosen);
  assert.equal(m.text,'xin lỗi hôm nay được không');
  m.undo();assert.equal(m.text,'xl hnay dc k');
  m.redo();assert.equal(m.text,'xin lỗi hôm nay được không');
});
test('repeated ambiguous choices keep the next word addressable',()=>{
  const m=create();m.load('xl nha t đến muộn');
  m.choose(suggestionsFor(m.text,m.text.length,m.index,'direct',m.ranges).find(r=>r.expansion==='tôi'));
  m.choose(suggestionsFor(m.text,m.text.length,m.index,'direct',m.ranges).find(r=>r.expansion==='xin lỗi'));
  assert.equal(m.text,'xin lỗi nha tôi đến muộn');
  assert.equal(pendingWords(m.text,m.index,'direct',m.ranges).length,0);
});
test('a completed paste prioritizes remaining abbreviations over prefixes of normal words',()=>{
  const m=create();m.load('hnay dc k, xl nha');
  const choices=suggestionsFor(m.text,m.text.length,m.index,'direct',m.ranges,true);
  assert.ok(choices.length>0 && choices.every(c=>c.trigger==='xl'));
  assert.ok(suggestionsFor('hna',3,m.index,'direct').some(c=>c.trigger==='hnay'));
});
test('after choosing the first ambiguous word the next one is suggested even after the caret',()=>{
  const m=create();m.load('xl nha t đến muộn');
  m.select(2);
  m.choose(suggestionsFor(m.text,2,m.index,'direct',m.ranges).find(c=>c.expansion==='xin lỗi'));
  const choices=suggestionsFor(m.text,m.current.start,m.index,'direct',m.ranges,true);
  assert.ok(choices.length>0 && choices.every(c=>c.trigger==='t'));
});
test('undo after further typing retains earlier transformations, redo restores typing',()=>{
  const m=create();m.load('hnay dc');const transformed=m.text;
  m.edit(m.text+' nhé',m.text.length+4);
  m.undo();assert.equal(m.text,transformed);
  m.redo();assert.equal(m.text,transformed+' nhé');
  m.undo();m.undo();assert.equal(m.text,'hnay dc');
});
test('a new edit after undo invalidates redo and clear can be undone',()=>{
  const m=create();m.load('hnay');m.undo();m.edit('hqua',4);
  assert.equal(m.redo(),false);m.clear();assert.equal(m.text,'');
  m.undo();assert.equal(m.text,'hqua');
});
test('continuous typing groups undo but stops at an automatic transformation',()=>{
  const m=create();
  for (const ch of 'hnay ') {m.edit(m.text+ch,m.text.length+1,undefined,true);m.transform();}
  assert.equal(m.text,'hôm nay ');
  m.undo();assert.equal(m.text,'hnay ');
  m.undo();assert.equal(m.text,'');
  m.redo();m.redo();
  for (const ch of 'nhé') m.edit(m.text+ch,m.text.length+1,undefined,true);
  m.undo();assert.equal(m.text,'hôm nay ');
});
test('generated output never loops or expands into a second unintended meaning',()=>{
  const m=new EditorModel(makeIndex([
    {trigger:'abc',expansion:'ko',status:'approved',auto_replace:true},
    {trigger:'ko',expansion:'không',status:'approved',auto_replace:true}
  ]));
  m.load('abc');assert.equal(m.text,'ko');
  m.edit(m.text+' hnay',m.text.length+5);m.transform(true);
  assert.equal(m.text,'ko hnay');
  assert.equal(pendingWords(m.text,m.index,'direct',m.ranges).length,0);
  // Editing the generated content itself makes it eligible again.
  m.edit('k0 hnay',2);assert.equal(m.ranges.length,0);
});
test('links, email, handles, hashtags, identifiers and code remain literal on paste',()=>{
  const tick=String.fromCharCode(96);
  const literals=['https://example.com/hnay?k=dc','www.example.com/ko','hnay@dc.vn','@hnay','#hnay','hnay_dc',tick+'hnay dc'+tick,tick.repeat(3)+'\nhnay dc\n'+tick.repeat(3)];
  const text=literals.join(' ')+'\nhnay dc k';
  const out=expandText(text,text.length,dictionary,'direct',true);
  assert.equal(out.text,literals.join(' ')+'\nhôm nay được không');
  assert.deepEqual(suggestionsFor('https://example.com/hnay',24,dictionary,'direct'),[]);
});
test('switching styles affects subsequent conversions and never bypasses moderation flags',()=>{
  const m=create();m.style='gentle';m.load('vcl xl');
  assert.equal(m.text,'vãi cả lúa xl');
  const governed=new EditorModel(makeIndex([{trigger:'hnay',expansion:'hôm nay',status:'approved',auto_replace:false}]));
  governed.load('hnay');assert.equal(governed.text,'hnay');
  governed.choose(suggestionsFor(governed.text,4,governed.index,'direct')[0]);
  assert.equal(governed.text,'hôm nay ');
});
