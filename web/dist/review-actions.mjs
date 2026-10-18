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
export function nextAfterReview(rows,processed){
  const first=rows.findIndex(row=>processed.has(row.id));
  return [...rows.slice(first+1),...rows.slice(0,first)].find(row=>!processed.has(row.id))?.id||null;
}
