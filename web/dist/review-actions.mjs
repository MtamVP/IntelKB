import {normalize} from './engine.mjs';

export function modeDefaultGaps(rows){
 const groups=new Map();
 for(const row of rows.filter(row=>row.status==='approved')){
  const key=normalize(row.trigger);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);
 }
 const gaps=[];
 for(const [trigger,group] of groups){
  const profane=group.filter(row=>row.category==='profanity'),safe=group.filter(row=>row.category!=='profanity'),modes=[];
  for(const [mode,pool] of [['direct',profane.length?profane:safe],['gentle',safe]]){
   if(pool.length>1&&pool.filter(row=>row['auto_'+mode]===true).length!==1)modes.push(mode);
  }
  if(modes.length)gaps.push({trigger,modes});
 }
 return gaps.sort((a,b)=>a.trigger.localeCompare(b.trigger,'vi'));
}
// A row action uses the selection only when its initiating row belongs to it.
export function reviewError(error){
  const missing=/^Choose (direct|gentle) default for (.+)$/.exec(error.message);
  if(missing)return {needsChoice:true,message:`Từ “${missing[2]}” có nhiều nghĩa trong chế độ ${missing[1]==='direct'?'nhắn tục':'nhắn nhẹ'}. Hãy chọn một nghĩa ưu tiên trong phần kiểm tra theo chế độ rồi duyệt lại. Lượt này chưa được lưu.`};
  if(error.message==='Default must be an approved or successfully reviewed entry')return {needsChoice:true,message:'Nghĩa ưu tiên bạn chọn chưa được công bố hoặc không được duyệt thành công trong lượt này. Hãy chọn cả dòng chứa nghĩa đó để duyệt cùng, hoặc chọn một nghĩa đã công bố.'};
  const info=[error.message,error.code&&`Mã: ${error.code}`,error.details,error.hint].filter(Boolean).join(' · ');
  return {needsChoice:false,message:`Không thể hoàn tất lượt duyệt. ${info}`};
}
export function reviewTargets(rows,selected,clickedId){
  const eligible=row=>['draft','pending'].includes(row.status);
  const clicked=rows.find(row=>row.id===clickedId);
  if(!clicked||!eligible(clicked))return [];
  return selected.has(clickedId)?rows.filter(row=>selected.has(row.id)&&eligible(row)):[clicked];
}
export function entryDiff(before,after){
  if(!before)return [];
  return ['trigger','expansion','category','auto_replace'].filter(key=>before[key]!==after[key]).map(key=>({key,before:before[key],after:after[key]}));
}
const reviewBase=row=>JSON.stringify({trigger:row.trigger,expansion:row.expansion,category:row.category,auto_replace:row.auto_replace,status:row.status,revision:row.revision,base_revision:row.base_revision});
export function makeReviewDraft(row,values,previous){return {...values,_base:previous?._base||reviewBase(row)};}
export function dirtyReviewDraft(draft){return Boolean(draft&&(draft.note||entryDiff(JSON.parse(draft._base),draft).length));}
export function staleReviewDraft(row,draft){return Boolean(draft&&dirtyReviewDraft(draft)&&draft._base!==reviewBase(row));}
export function nextAfterReview(rows,processed){
  const first=rows.findIndex(row=>processed.has(row.id));
  return [...rows.slice(first+1),...rows.slice(0,first)].find(row=>!processed.has(row.id))?.id||null;
}
