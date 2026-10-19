export const TEXT_TOOLS = [
  {id:'upper',label:'CHỮ HOA',description:'Đổi thành chữ hoa.',run:text=>text.toLocaleUpperCase('vi')},
  {id:'lower',label:'chữ thường',description:'Đổi thành chữ thường.',run:text=>text.toLocaleLowerCase('vi')},
  {id:'title',label:'Viết Hoa Mỗi Từ',description:'Viết hoa đầu từng từ, phần còn lại viết thường.',run:text=>text.toLocaleLowerCase('vi').replace(/\p{L}[\p{L}\p{M}]*/gu,word=>word.replace(/^\p{L}/u,letter=>letter.toLocaleUpperCase('vi')))},
  {id:'sentence',label:'Viết hoa đầu câu',description:'Giữ nguyên chữ khác, viết hoa chữ đầu sau dấu kết câu.',run:text=>text.replace(/(^|[.!?]\s+)([\p{L}])/gu,(_,prefix,letter)=>prefix+letter.toLocaleUpperCase('vi'))},
  {id:'unaccent',label:'Bỏ dấu tiếng Việt',description:'Bỏ dấu chữ Latin/Việt và đổi đ/Đ; giữ chữ hệ khác.',run:text=>text.normalize('NFD').replace(/([A-Za-z])\p{M}+/gu,'$1').replace(/đ/g,'d').replace(/Đ/g,'D').normalize('NFC')},
  {id:'nfc',label:'Chuẩn hóa Unicode',description:'Gộp ký tự tổ hợp về NFC, giữ nguyên dấu.',run:text=>text.normalize('NFC')},
  {id:'spaces',label:'Gọn khoảng trắng',description:'Gộp khoảng trắng trong mỗi dòng; giữ các dòng.',run:text=>text.replace(/\r\n?/g,'\n').split('\n').map(line=>line.replace(/[\t \u00a0]+/g,' ').trim()).join('\n')},
  {id:'trim',label:'Xén đầu/cuối dòng',description:'Bỏ khoảng trắng thừa ở hai đầu từng dòng.',run:text=>text.replace(/\r\n?/g,'\n').split('\n').map(line=>line.trim()).join('\n')},
  {id:'blank-lines',label:'Bỏ dòng trống',description:'Bỏ các dòng không có nội dung.',run:text=>text.replace(/\r\n?/g,'\n').split('\n').filter(line=>line.trim()).join('\n')},
  {id:'unique-lines',label:'Bỏ dòng trùng',description:'Giữ dòng đầu tiên; phân biệt hoa/thường và dấu.',run:text=>{const seen=new Set();return text.replace(/\r\n?/g,'\n').split('\n').filter(line=>{const key=line.normalize('NFC');if(seen.has(key))return false;seen.add(key);return true;}).join('\n');}},
  {id:'sort-lines',label:'Sắp xếp dòng A–Z',description:'Sắp theo tiếng Việt, có nhận biết số.',run:text=>text.replace(/\r\n?/g,'\n').split('\n').sort((a,b)=>a.localeCompare(b,'vi',{numeric:true})).join('\n')},
  {id:'number-lines',label:'Đánh số các dòng',description:'Thêm 1., 2., 3.… trước mỗi dòng có nội dung.',run:text=>{let n=0;return text.replace(/\r\n?/g,'\n').split('\n').map(line=>line.trim()?`${++n}. ${line}`:line).join('\n');}},
];
export function applyTextTool(id,text){
 const tool=TEXT_TOOLS.find(tool=>tool.id===id);if(!tool)throw new Error('Công cụ không hợp lệ.');return tool.run(String(text));
}
export function textStats(text){
 const value=String(text),supported=typeof Intl.Segmenter==='function';
 const words=supported?[...new Intl.Segmenter('vi',{granularity:'word'}).segment(value)].filter(part=>part.isWordLike).length:(value.match(/[\p{L}\p{N}][\p{L}\p{M}\p{N}]*/gu)||[]).length;
 return {characters:[...value].length,graphemes:supported?[...new Intl.Segmenter('vi',{granularity:'grapheme'}).segment(value)].length:[...value].length,words,lines:value?value.split(/\r\n|\r|\n/).length:0};
}
export const QUICK_SYMBOLS=['→','←','↔','✓','✕','•','…','—','“','”','‘','’','₫','€','£','¥','©','®','™','°','±','×','÷','≤','≥','≠','∞','½','¼','¾','🙂','😂','❤️','👍','🙏','🎉'];
