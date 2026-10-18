import {normalize} from './engine.mjs';
import {validateEntry} from './dictionary-store.mjs';
export const pairIdentity = row => JSON.stringify([normalize(String(row.trigger||'')),normalize(String(row.expansion||''))]);
export function findPair(rows,input,excludeId=null){
  const key=pairIdentity(input);
  return rows.find(row=>row.id!==excludeId && pairIdentity(row)===key) || null;
}
// Parse Excel TSV, CSV (including quoted newlines), or one "alias → meaning" per line.
export function parseContributions(text,existing=[],category='chat'){
  const delimiter=text.includes('\t')?'\t':',';
  let records=[],row=[],cell='',quoted=false;
  for(let i=0;i<=text.length;i++){
    const ch=text[i];
    if(ch==='"'){if(quoted && text[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}
    else if(!quoted && (ch===delimiter || ch==='\n' || ch===undefined)){
      row.push(cell.trim());cell='';
      if(ch!==delimiter){if(row.some(Boolean))records.push(row);row=[];}
    }else if(ch!==undefined && ch!=='\r')cell+=ch;
  }
  if(quoted)return [{line:1,error:'Dấu ngoặc kép chưa đóng.'}];
  if(records[0] && /^(trigger|viết tắt|từ viết tắt)$/iu.test(records[0][0]))records.shift();
  if(records.length>20)return [{line:1,error:'Mỗi lượt tối đa 20 dòng. Hãy chia nhỏ nội dung.'}];
  const seen=new Set();
  return records.map((cells,i)=>{
    if(cells.length===1)cells=cells[0].split(/\s*(?:→|=>)\s*/u);
    try{
      if(cells.length<2 || cells.length>3)throw new Error('Dùng 2 cột: viết tắt và nghĩa; có thể thêm cột nhóm.');
      const value=validateEntry({trigger:cells[0],expansion:cells[1],category:cells[2]||category,auto_replace:false});
      const key=pairIdentity(value);let error='';
      if(seen.has(key))error='Trùng cặp trong nội dung vừa dán.';
      else if(findPair(existing,value))error='Cặp viết tắt và nghĩa đã có trong danh sách.';
      seen.add(key);return {line:i+1,value,error};
    }catch(error){return {line:i+1,error:error.message};}
  });
}
export function groupReviewRows(rows){
  const groups=new Map();for(const row of rows){const key=normalize(row.trigger);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);}
  return [...groups.entries()];
}
