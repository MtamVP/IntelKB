import {publicCatalogue} from './dist/catalogue.mjs';

// Approval is for the bundled editorial corpus, never anonymous contributions.
export function referenceApprovalSql(words) {
  const quote=value=>"'"+value.replaceAll("'","''")+"'";
  const values=publicCatalogue(words,[]).map(row=>`(${[row.trigger,row.expansion,row.category].map(quote).join(',')},${row.auto_replace},${row.auto_direct},${row.auto_gentle})`).join(',\n');
  return `-- Approve untouched bundled words. Run after review-efficiency-upgrade.sql.
-- Preserve existing owner decisions, edited drafts, and all public proposals.
begin;
lock table public.intelkb_dictionary in share row exclusive mode;
with bundled(trigger,expansion,category,auto_replace,auto_direct,auto_gentle) as (values
${values}
), eligible as (
 select d.id,b.auto_replace,b.auto_direct,b.auto_gentle
 from public.intelkb_dictionary d join bundled b on d.trigger=b.trigger and d.expansion=b.expansion and d.category=b.category
 where d.source='bootstrap' and d.status='draft' and d.revision=1 and d.reviewed_at is null
 and not exists(select 1 from public.intelkb_dictionary live
   where live.status='approved' and public.intelkb_alias_key(live.trigger)=public.intelkb_alias_key(d.trigger))
)
update public.intelkb_dictionary d set status='approved',auto_replace=e.auto_replace,
 auto_direct=e.auto_direct,auto_gentle=e.auto_gentle,reviewed_at=now(),updated_at=now(),revision=d.revision+1
from eligible e where d.id=e.id;
commit;
`;
}
