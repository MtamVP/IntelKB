import {normalize,defaultAutoFill,makeIndex,automaticMeaning} from './engine.mjs';
const catalogueKey = row => `${normalize(row.trigger)}\u0000${normalize(row.expansion)}`;
const keyboardTrigger = row => normalize(row.trigger);
function uniquePairs(rows) {
  const pairs=new Map();
  for(const row of rows){
    const key=catalogueKey(row),old=pairs.get(key);
    if(!old || (row.revision||0)>(old.revision||0) ||
      ((row.revision||0)===(old.revision||0) && row.auto_replace===false)) pairs.set(key,row);
  }
  return [...pairs.values()];
}
// Bundled demo entries keep the playground usable during gradual moderation.
// A published trigger replaces ALL demo meanings for that trigger, so old
// meanings and auto-replace permissions cannot override the owner's decision.
export function keyboardDictionary(samples, serverRows = []) {
  const approved=uniquePairs(serverRows.filter(row=>row.status==='approved'));
  const managed=new Set(approved.map(keyboardTrigger));
  return [...uniquePairs(samples).filter(row=>!managed.has(keyboardTrigger(row))).map(row=>({...row,demo:true})),
    ...approved.map(row=>({...row,demo:false}))];
}
export function publicCatalogue(samples, approved) {
  const rows = new Map(uniquePairs(samples).map((row,i)=>[catalogueKey(row),{...row,auto_replace:row.auto_replace??defaultAutoFill(row.trigger),id:`sample-${i}`,sample:true}]));
  for (const row of uniquePairs(approved.filter(row=>row.status==='approved'))) {
    if (row.status === 'approved') rows.set(catalogueKey(row),{...row,sample:false});
  }
  const result=[...rows.values()],sampleIndex=makeIndex(result.filter(row=>row.sample));
  // Demo labels reflect the same mode-aware policy as the playground.
  for(const row of result.filter(row=>row.sample)){
    row.auto_direct=automaticMeaning(row.trigger,sampleIndex,'direct')?.id===row.id;
    row.auto_gentle=automaticMeaning(row.trigger,sampleIndex,'gentle')?.id===row.id;
    row.auto_replace=row.auto_direct||row.auto_gentle;
  }
  return result.sort((a,b)=>a.trigger.localeCompare(b.trigger,'vi') || a.expansion.localeCompare(b.expansion,'vi'));
}
const catalogueSearch = text => text.normalize('NFD').replace(/\p{M}/gu,'').replace(/[đĐ]/g,'d').toLocaleLowerCase('vi');
export function filterCatalogue(rows,{query='',category='',status='',auto=''}={}) {
  const search=catalogueSearch(query.trim());
  return rows.filter(row=>(!category || row.category===category) && (!status || (status==='sample'?row.sample:!row.sample))
    && (!auto || (auto==='on'?row.auto_replace===true:row.auto_replace!==true))
    && catalogueSearch(`${row.trigger} ${row.expansion}`).includes(search));
}
