import test from 'node:test';
import assert from 'node:assert/strict';
import {validateEntry} from '../dist/dictionary-store.mjs';
test('word validation normalizes Unicode and rejects invalid or empty meanings',()=>{
 const input={trigger:' ĐCMM ',expansion:'một nghĩa',category:'chat'};
 assert.equal(validateEntry(input).trigger,'đcmm');
 assert.throws(()=>validateEntry({...input,trigger:'<script>'}));
 assert.throws(()=>validateEntry({...input,expansion:'ĐCMM'}));
 assert.throws(()=>validateEntry({...input,expansion:' '}));
 assert.throws(()=>validateEntry({...input,category:'invalid'}));
});
