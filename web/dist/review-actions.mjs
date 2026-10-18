// A row action uses the selection only when its initiating row belongs to it.
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
