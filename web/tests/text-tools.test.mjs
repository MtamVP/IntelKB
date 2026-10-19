import test from 'node:test';
import assert from 'node:assert/strict';
import {TEXT_TOOLS,applyTextTool,textStats} from '../dist/text-tools.mjs';
import {EditorModel} from '../dist/editor-model.mjs';
import {makeIndex} from '../dist/engine.mjs';

test('case and accent tools handle Vietnamese, decomposed accents and other writing systems',()=>{
 assert.equal(applyTextTool('upper','đặng thị'), 'ĐẶNG THỊ');
 assert.equal(applyTextTool('lower','ĐẶNG THỊ'), 'đặng thị');
 assert.equal(applyTextTool('title','ĐẶNG tHỊ 🙂 𐐨'), 'Đặng Thị 🙂 𐐀');
 assert.equal(applyTextTool('unaccent','Đặng THỊ'.normalize('NFD')),'Dang THI');
 assert.equal(applyTextTool('unaccent','Việt नमस्ते 한글'),'Viet नमस्ते 한글');
 assert.equal(applyTextTool('sentence','xin chào. hẹn NASA nhé! đúng rồi'),'Xin chào. Hẹn NASA nhé! Đúng rồi');
 assert.equal(applyTextTool('nfc','mới'.normalize('NFD')),'mới');
});
test('line tools preserve intended boundaries and distinguish case-sensitive duplicates',()=>{
 assert.equal(applyTextTool('spaces','  a  b \r\n\tc\t d  '),'a b\nc d');
 assert.equal(applyTextTool('trim','  a  b \r\n\tc\t d  '),'a  b\nc\t d');
 assert.equal(applyTextTool('blank-lines','a\n \n\nb'),'a\nb');
 assert.equal(applyTextTool('unique-lines','mới\nmới\nMới\n'+ 'mới'.normalize('NFD')),'mới\nMới');
 assert.equal(applyTextTool('sort-lines','a10\na2\na1'),'a1\na2\na10');
 assert.equal(applyTextTool('number-lines','a\n\nb'),'1. a\n\n2. b');
 for(const tool of TEXT_TOOLS)assert.equal(applyTextTool(tool.id,''),'');
 assert.throws(()=>applyTextTool('unknown','abc'),/không hợp lệ/);
});
test('statistics count Unicode characters, graphemes, words and CRLF lines separately',()=>{
 assert.deepEqual(textStats(''),{characters:0,graphemes:0,words:0,lines:0});
 const stats=textStats('a\u0301 🙂\r\nViệt');assert.equal(stats.words,2);assert.equal(stats.lines,2);assert.ok(stats.graphemes<stats.characters);
});
test('tool replacement preserves the suffix, selected result, protected text, undo and redo',()=>{
 const model=new EditorModel(makeIndex([{trigger:'ms',expansion:'mới',category:'chat'}]));
 model.load('🙂 trước ms sau',{},false);const start=model.text.indexOf('ms');model.select(start,start+2);
 model.replace(start,start+2,'MS',{selectResult:true});
 assert.equal(model.text,'🙂 trước MS sau');assert.equal(model.current.start,start);assert.equal(model.current.end,start+2);
 model.transform(true);assert.equal(model.text,'🙂 trước MS sau');
 model.undo();assert.equal(model.text,'🙂 trước ms sau');model.redo();assert.equal(model.text,'🙂 trước MS sau');
 assert.equal(model.current.report,null);assert.throws(()=>model.replace(-1,3,'x'),/không hợp lệ/);
});
test('literal snippets insert without applying dictionary rules to abbreviations inside them',()=>{
 const model=new EditorModel(makeIndex([{trigger:'ms',expansion:'mới',category:'chat'}]));
 model.load('🙂!',{},false);model.replace(2,2,'ms\nhttps://example.com');
 const expected='🙂ms\nhttps://example.com!';assert.equal(model.text,expected);
 model.transform(true);assert.equal(model.text,expected);model.undo();assert.equal(model.text,'🙂!');
});
