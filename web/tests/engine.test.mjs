import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {makeIndex, suggestionsFor, autoCandidate, replaceSuggestion, telexWord, applyTone, pendingWords, expandText} from '../dist/engine.mjs';
const words = JSON.parse(fs.readFileSync(new URL('../dist/words.json', import.meta.url)));
const index = makeIndex(words);
test('ordinary aliases expand on space, not inside words', () => {
  const text='hnay ';
  assert.equal(replaceSuggestion(text,autoCandidate(text,text.length,index,'direct')).text,'hôm nay ');
  assert.equal(autoCandidate('keyboard ',9,index,'direct'),null);
  assert.equal(autoCandidate('lag ',4,index,'direct'),null);
  assert.equal(autoCandidate('nha ',4,index,'direct'),null);
});
test('ambiguous meanings need explicit selection in both styles', () => {
  for (const style of ['direct','gentle']) assert.equal(autoCandidate('xl ',3,index,style),null);
  assert.equal(suggestionsFor('xl',2,index,'direct').length,2);
});
test('style controls explicit vcl expansion', () => {
  assert.equal(autoCandidate('vcl ',4,index,'direct').expansion,'vãi cả lồn');
  assert.equal(autoCandidate('vcl ',4,index,'gentle').expansion,'vãi cả lúa');
  assert.ok(!suggestionsFor('đcmm',4,index,'gentle').some(r=>r.category==='profanity'));
});
test('native UTF-16 caret and punctuation survive mid-sentence selection', () => {
  const text='🙂 hnay, đi chơi';
  const item=suggestionsFor(text,7,index,'direct')[0];
  assert.equal(item.start,3);
  const out=replaceSuggestion(text,item);
  assert.equal(out.text,'🙂 hôm nay, đi chơi');
  assert.equal(out.caret,10);
});
test('prefix suggestions and uppercase input', () => {
  assert.ok(suggestionsFor('hna',3,index,'direct').some(r=>r.trigger==='hnay'));
  const item=suggestionsFor('HNAY',4,index,'direct')[0];
  assert.equal(replaceSuggestion('HNAY',item).text,'HÔM NAY ');
});
test('virtual Telex and Vietnamese tones', () => {
  const type=s=>[...s].reduce((word,key)=>telexWord(word,key),'');
  assert.equal(type('ddcmm'),'đcmm');
  assert.equal(type('tieengs'),'tiếng');
  assert.equal(type('dduowngf'),'đường');
  assert.equal(applyTone('chơi','s'),'chới');
  assert.equal(applyTone('tiếng','z'),'tiêng');
});
test('whole sentence expands every unambiguous alias without rewriting normal words', () => {
  const text='hnay dc k, lag nha';
  const result=expandText(text,text.length,index,'direct',true);
  assert.equal(result.text,'hôm nay được không, lag nha');
  assert.equal(result.changes.length,3);
  assert.equal(result.caret,result.text.length);
});
test('incremental auto continues across four words and preserves the incomplete last word', () => {
  let text='';
  for (const key of 'hnay dc k ') {
    text+=key; text=expandText(text,text.length,index,'direct').text;
  }
  assert.equal(text,'hôm nay được không ');
  assert.equal(expandText('hnay',4,index,'direct').text,'hnay');
});
test('find earlier aliases at sentence end and select the second after replacing the first', () => {
  let text='xl nha t đến muộn';
  assert.deepEqual(pendingWords(text,index,'direct').map(t=>t.trigger),['xl','t']);
  const item=suggestionsFor(text,text.length,index,'direct').find(r=>r.expansion==='tôi');
  text=replaceSuggestion(text,item).text;
  assert.equal(text,'xl nha tôi đến muộn');
  assert.ok(suggestionsFor(text,text.length,index,'direct').some(r=>r.trigger==='xl'));
});
test('click in middle of an abbreviation addresses the whole token', () => {
  const match=suggestionsFor('hnay dc',2,index,'direct')[0];
  assert.equal(match.start,0);assert.equal(match.end,4);
  assert.equal(replaceSuggestion('hnay dc',match).text,'hôm nay dc');
});
test('custom dictionary can enable auto and disable an existing builtin replacement', () => {
  const personal=makeIndex([...words,{trigger:'zztest',expansion:'từ mới',category:'chat',custom:true,auto_replace:true},{trigger:'hnay',expansion:'hôm nay',category:'chat',custom:true,auto_replace:false}]);
  assert.equal(expandText('zztest hnay',11,personal,'direct',true).text,'từ mới hnay');
});
test('published words obey the moderator auto-replace decision',()=>{
  const approved=makeIndex([{trigger:'hnay',expansion:'hôm nay',category:'chat',status:'approved',auto_replace:false},{trigger:'vcl',expansion:'vãi cả lồn',category:'profanity',status:'approved',auto_replace:false}]);
  assert.equal(expandText('hnay vcl',8,approved,'direct',true).text,'hnay vcl');
  assert.equal(autoCandidate('hnay ',5,approved,'direct'),null);
});

test('common chat variants expand on space, paste and sentence completion',()=>{
  assert.equal(autoCandidate('ms ',3,index,'direct').expansion,'mới');
  assert.equal(expandText('ms ',3,index,'direct').text,'mới ');
  const text='ms nhg nhiu thui';
  assert.equal(expandText(text,text.length,index,'direct',true).text,'mới nhưng nhiều thôi');
  assert.equal(expandText('ms',2,index,'direct').text,'ms');
  assert.equal(expandText('ms',2,index,'direct',true).text,'mới');
});
test('chat ms never rewrites a millisecond measurement or ignores a moderator restriction',()=>{
  const text='lag 20 ms, hnay ms vào';
  assert.equal(expandText(text,text.length,index,'direct',true).text,'lag 20 ms, hôm nay mới vào');
  assert.equal(autoCandidate('20 ms ',6,index,'direct'),null);
  const governed=makeIndex([{trigger:'ms',expansion:'mới',status:'approved',auto_replace:false}]);
  assert.equal(expandText('ms ',3,governed,'direct',true).text,'ms ');
});
