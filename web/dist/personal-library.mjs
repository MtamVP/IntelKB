export const LIBRARY_LIMIT=300;
const libraryKey='intelkb.personal-library.v1';
export function validateLibraryItem(input){
 if(!input||typeof input!=='object'||Array.isArray(input))throw new Error('Mục lưu không hợp lệ.');
 const title=String(input.title||'').trim(),text=String(input.text??'');
 if(!title||title.length>80)throw new Error('Tên cần từ 1 đến 80 ký tự.');
 if(!text.trim()||text.length>10000)throw new Error('Nội dung cần có chữ và tối đa 10.000 ký tự.');
 return {title,text,kind:input.kind==='clip'?'clip':'phrase',pinned:input.pinned===true};
}
export class PersonalLibrary {
 constructor(storage){this.storage=storage;this.rows=[];this.error='';this.serialized=null;try{this.storage=storage||globalThis.localStorage;const raw=this.storage.getItem(libraryKey);this.serialized=raw;if(raw){const parsed=JSON.parse(raw);if(!Array.isArray(parsed)||parsed.length>LIBRARY_LIMIT)throw new Error('Invalid library');this.rows=parsed.map(row=>{if(typeof row?.id!=='string'||!row.id.trim())throw new Error('Invalid identity');return {...validateLibraryItem(row),id:row.id,updatedAt:String(row.updatedAt||'')};});if(new Set(this.rows.map(row=>row.id)).size!==this.rows.length)throw new Error('Invalid identity');}}catch{this.error='Không đọc được bộ lưu cá nhân trên thiết bị. Dữ liệu cũ chưa bị ghi đè; hãy kiểm tra bộ nhớ trình duyệt.';}}
 write(rows){let current;try{current=this.storage.getItem(libraryKey);}catch{throw new Error('Trình duyệt đang chặn bộ nhớ cục bộ.');}if(current!==this.serialized)throw new Error('Bộ lưu đã thay đổi trong tab khác. Tải lại trang trước khi lưu để tránh ghi đè.');const value=JSON.stringify(rows);try{this.storage.setItem(libraryKey,value);}catch{throw new Error('Không lưu được trên thiết bị. Bộ nhớ có thể đã đầy hoặc bị trình duyệt chặn.');}this.rows=rows;this.serialized=value;this.error='';}
 save(input,id=null){
  if(this.error)throw new Error(this.error);
  const value=validateLibraryItem(input),old=id?this.rows.find(row=>row.id===id):null;
  if(id&&!old)throw new Error('Mục đã thay đổi hoặc không còn tồn tại.');
  if(!old&&this.rows.length>=LIBRARY_LIMIT)throw new Error(`Tối đa ${LIBRARY_LIMIT} mục lưu trên thiết bị.`);
  const row={...value,id:old?.id||crypto.randomUUID(),updatedAt:new Date().toISOString()};
  this.write(old?this.rows.map(item=>item.id===id?row:item):[...this.rows,row]);return row;
 }
 remove(id){const row=this.rows.find(row=>row.id===id);if(!row)return null;this.write(this.rows.filter(row=>row.id!==id));return row;}
 export(){if(this.error)throw new Error(this.error);return {format:'intelkb-personal-library',version:1,items:this.rows.map(({title,text,kind,pinned})=>({title,text,kind,pinned}))};}
 import(input){
  if(this.error)throw new Error(this.error);
  if(!input||input.format!=='intelkb-personal-library'||input.version!==1||!Array.isArray(input.items)||input.items.length>LIBRARY_LIMIT)throw new Error('File không đúng định dạng sao lưu IntelKB phiên bản 1.');
  const values=input.items.map(validateLibraryItem),seen=new Set(this.rows.map(row=>JSON.stringify([row.title,row.text,row.kind]))),add=[];
  for(const value of values){const key=JSON.stringify([value.title,value.text,value.kind]);if(seen.has(key))continue;seen.add(key);add.push({...value,id:crypto.randomUUID(),updatedAt:new Date().toISOString()});}
  if(this.rows.length+add.length>LIBRARY_LIMIT)throw new Error(`Sau khi nhập sẽ vượt ${LIBRARY_LIMIT} mục. Chưa thay đổi dữ liệu.`);
  this.write([...this.rows,...add]);return {added:add.length,skipped:values.length-add.length};
 }
}
