import {normalize} from './engine.mjs';
import {validateEntry} from './dictionary-store.mjs';
export const pairIdentity = row => JSON.stringify([normalize(String(row.trigger||'')),normalize(String(row.expansion||''))]);
export const entryIdentity = row => JSON.stringify([pairIdentity(row),row.category,Boolean(row.auto_replace)]);
export function classifyContribution(rows,input,target=null,action='new'){
  const identical=rows.find(row=>entryIdentity(row)===entryIdentity(input));
  if(identical)return {action:'duplicate',target:identical};
  if(target&&action==='edit')return {action:target.sample?'new':'edit',target:target.sample?null:target};
  const pair=findPair(rows,input);
  if(pair)return {action:pair.sample?'new':'edit',target:pair.sample?null:pair};
  if(action==='add_meaning'&&target)return {action:target.sample?'new':action,target:target.sample?null:target};
  const aliases=rows.filter(row=>normalize(row.trigger)===normalize(input.trigger));
  if(aliases.length>1)return {action:'choose',target:null};
  if(aliases.length===1&&!aliases[0].sample)return {action:'edit',target:aliases[0]};
  return {action:'new',target:null};
}
export function findPair(rows,input,excludeId=null){
  const key=pairIdentity(input);
  return rows.find(row=>row.id!==excludeId && pairIdentity(row)===key) || null;
}
// Search the abbreviation while it is still being typed; counts are meanings, not raw duplicates.
export function findTriggerMatches(rows,text,limit=6){
  const query=normalize(String(text||''));
  if(!query)return {query,exact:0,total:0,rows:[]};
  const found=new Map();
  for(const row of rows){
    if(normalize(row.trigger).includes(query))found.set(pairIdentity(row),row);
  }
  const matches=[...found.values()];
  const rank=row=>normalize(row.trigger)===query?0:normalize(row.trigger).startsWith(query)?1:2;
  matches.sort((a,b)=>rank(a)-rank(b)||a.trigger.localeCompare(b.trigger,'vi')||a.expansion.localeCompare(b.expansion,'vi'));
  return {query,exact:matches.filter(row=>normalize(row.trigger)===query).length,total:matches.length,rows:matches.slice(0,limit)};
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
      const aliases=existing.filter(row=>normalize(row.trigger)===normalize(value.trigger));
      const original=findPair(existing,value)||(aliases.length===1?aliases[0]:null);
      // Missing pasted columns mean keep the original settings, not silently turn them off.
      if(original){value.auto_replace=Boolean(original.auto_replace);value.category=cells[2]||original.category||category;}
      const key=entryIdentity(value),context=classifyContribution(existing,value);let error='';
      if(seen.has(key))error='Trùng cặp trong nội dung vừa dán.';
      else if(context.action==='duplicate')error='Toàn bộ thông tin đã có trong danh sách.';
      else if(context.action==='choose')error='Có nhiều nghĩa: chọn mục cần sửa hoặc bổ sung nghĩa ở chế độ Một từ.';
      seen.add(key);return {line:i+1,value,error,context};
    }catch(error){return {line:i+1,error:error.message};}
  });
}
export function groupReviewRows(rows){
  const groups=new Map();for(const row of rows){const key=normalize(row.trigger);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);}
  return [...groups.entries()];
}
