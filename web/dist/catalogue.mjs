const catalogueKey = row => `${row.trigger.normalize('NFC').toLocaleLowerCase('vi')}\u0000${row.expansion.normalize('NFC').toLocaleLowerCase('vi')}`;
export function publicCatalogue(samples, approved) {
  const rows = new Map(samples.map((row,i)=>[catalogueKey(row),{...row,id:`sample-${i}`,sample:true}]));
  for (const row of approved) {
    if (row.status === 'approved') rows.set(catalogueKey(row),{...row,sample:false});
  }
  return [...rows.values()].sort((a,b)=>a.trigger.localeCompare(b.trigger,'vi') || a.expansion.localeCompare(b.expansion,'vi'));
}
const catalogueSearch = text => text.normalize('NFD').replace(/\p{M}/gu,'').replace(/[đĐ]/g,'d').toLocaleLowerCase('vi');
export function filterCatalogue(rows,{query='',category='',status=''}={}) {
  const search=catalogueSearch(query.trim());
  return rows.filter(row=>(!category || row.category===category) && (!status || (status==='sample'?row.sample:!row.sample))
    && catalogueSearch(`${row.trigger} ${row.expansion}`).includes(search));
}
