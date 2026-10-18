// A row action uses the selection only when its initiating row belongs to it.
export function reviewTargets(rows,selected,clickedId){
  const eligible=row=>['draft','pending'].includes(row.status);
  const clicked=rows.find(row=>row.id===clickedId);
  if(!clicked||!eligible(clicked))return [];
  return selected.has(clickedId)?rows.filter(row=>selected.has(row.id)&&eligible(row)):[clicked];
}
