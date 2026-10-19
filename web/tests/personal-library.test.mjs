import test from 'node:test';
import assert from 'node:assert/strict';
import {PersonalLibrary,LIBRARY_LIMIT} from '../dist/personal-library.mjs';
const memory=()=>{const data=new Map();return {getItem:key=>data.get(key)??null,setItem:(key,value)=>data.set(key,value)};};
const item={title:'Chào khách',text:'Chào bạn!\nHẹn gặp lại 🙂',kind:'phrase',pinned:false};
test('personal phrases retain raw content, can be edited, pinned, removed and restored locally',()=>{
 const storage=memory(),library=new PersonalLibrary(storage);const saved=library.save(item);
 assert.equal(library.rows.length,1);assert.ok(saved.id);assert.equal(new PersonalLibrary(storage).rows[0].text,item.text);
 const edited=library.save({...item,title:'Tên mới',pinned:true},saved.id);assert.equal(edited.id,saved.id);assert.ok(edited.pinned);
 const removed=library.remove(saved.id);assert.equal(library.rows.length,0);library.save(removed);assert.equal(library.rows[0].text,item.text);
 assert.throws(()=>library.save({...item,text:'  '}),/Nội dung/);assert.throws(()=>library.save({...item,title:'a'.repeat(81)}),/Tên/);
});
test('backup import merges without replacing existing items, duplicates or metadata',()=>{
 const library=new PersonalLibrary(memory());library.save({...item,pinned:true});
 const backup=library.export();backup.items[0].pinned=false;backup.items.push({...item,title:'Khác',kind:'clip'});
 const result=library.import(backup);assert.deepEqual(result,{added:1,skipped:1});assert.equal(library.rows.length,2);assert.ok(library.rows[0].pinned);
 assert.deepEqual(library.import(backup),{added:0,skipped:2});
 assert.deepEqual(Object.keys(library.export().items[0]).sort(),['kind','pinned','text','title']);
});
test('invalid or oversized import is atomic and cannot inject arbitrary fields or IDs',()=>{
 const library=new PersonalLibrary(memory());library.save(item);const before=library.export();
 assert.throws(()=>library.import({format:'other',version:1,items:[]}),/định dạng/);
 assert.throws(()=>library.import({format:before.format,version:1,items:[{...item,title:'new'},{title:'bad',text:''}]}),/Nội dung/);
 assert.deepEqual(library.export(),before);
 library.import({format:before.format,version:1,items:[{...item,title:'new',id:'attacker',status:'approved',pinned:true}]});
 assert.notEqual(library.rows[1].id,'attacker');assert.equal(library.rows[1].status,undefined);
 const tooMany=Array.from({length:LIBRARY_LIMIT},(_,i)=>({...item,title:'item'+i}));
 assert.throws(()=>library.import({format:before.format,version:1,items:tooMany}),/vượt/);assert.equal(library.rows.length,2);
});
test('storage failures do not report a successful write or mutate in-memory data',()=>{
 const storage=memory(),library=new PersonalLibrary(storage);library.save(item);const original=library.rows;
 storage.setItem=()=>{throw new Error('quota');};assert.throws(()=>library.save({...item,title:'new'}),/Không lưu/);assert.equal(library.rows,original);
 const broken=new PersonalLibrary({getItem:()=>'{bad',setItem:()=>{throw new Error('must not overwrite');}});
 assert.ok(broken.error);assert.throws(()=>broken.save(item),/Dữ liệu cũ/);assert.throws(()=>broken.export(),/Dữ liệu cũ/);
});
test('a stale tab cannot overwrite changes from another tab',()=>{
 const storage=memory(),first=new PersonalLibrary(storage),second=new PersonalLibrary(storage);first.save(item);
 assert.throws(()=>second.save({...item,title:'stale'}),/tab khác/);assert.equal(second.rows.length,0);
 assert.equal(new PersonalLibrary(storage).rows[0].title,item.title);
});
