import {publicCatalogue} from './dist/catalogue.mjs';

// Approval is for the bundled editorial corpus, never anonymous contributions.
export function referenceApprovalSql(words) {
  const quote=value=>"'"+value.replaceAll("'","''")+"'";
  const values=publicCatalogue(words,[]).map(row=>`(${[row.trigger,row.expansion,row.category].map(quote).join(',')},${row.auto_replace},${row.auto_direct},${row.auto_gentle})`).join(',\n');
  return `-- Approve untouched bundled words. Run after review-efficiency-upgrade.sql.
-- Preserve existing owner decisions, edited drafts, and all public proposals.
begin;
lock table public.intelkb_dictionary in share row exclusive mode;
-- Exact duplicates are merged into the published entry, with a private full backup.
create table if not exists public.intelkb_bootstrap_archive(
 id uuid primary key,published_id uuid not null,original_row jsonb not null,archived_at timestamptz not null default now()
);
alter table public.intelkb_bootstrap_archive enable row level security;
revoke all on public.intelkb_bootstrap_archive from anon,authenticated;
grant select on public.intelkb_bootstrap_archive to authenticated;
drop policy if exists intelkb_bootstrap_archive_owner on public.intelkb_bootstrap_archive;
create policy intelkb_bootstrap_archive_owner on public.intelkb_bootstrap_archive for select to authenticated using(public.intelkb_is_admin());
create temp table intelkb_bundled_approval on commit drop as
with bundled(trigger,expansion,category,auto_replace,auto_direct,auto_gentle) as (values
${values}
)
 select d.id,b.auto_replace,b.auto_direct,b.auto_gentle,
 exists(select 1 from public.intelkb_dictionary live where live.status='approved'
   and public.intelkb_alias_key(live.trigger)=public.intelkb_alias_key(d.trigger)) as managed,
 (select live.id from public.intelkb_dictionary live where live.status='approved'
   and public.intelkb_pair_key(live.trigger,live.expansion)=public.intelkb_pair_key(d.trigger,d.expansion) limit 1) as published_id
 from public.intelkb_dictionary d join bundled b on d.trigger=b.trigger and d.expansion=b.expansion and d.category=b.category
 where d.source='bootstrap' and d.status='draft' and d.revision=1 and d.reviewed_at is null;
insert into public.intelkb_bootstrap_archive(id,published_id,original_row)
 select d.id,e.published_id,to_jsonb(d) from public.intelkb_dictionary d join intelkb_bundled_approval e on e.id=d.id
 where e.published_id is not null on conflict(id) do nothing;
delete from public.intelkb_dictionary d using intelkb_bundled_approval e,public.intelkb_bootstrap_archive a
 where d.id=e.id and a.id=d.id and e.published_id is not null and a.original_row=to_jsonb(d);
-- Existing groups keep their owner-selected defaults; new meanings do not replace them.
update public.intelkb_dictionary d set status='approved',auto_replace=not e.managed and e.auto_replace,
 auto_direct=not e.managed and e.auto_direct,auto_gentle=not e.managed and e.auto_gentle,
 reviewed_at=now(),updated_at=now(),revision=d.revision+1
from intelkb_bundled_approval e where d.id=e.id and e.published_id is null;
-- A group that previously had one approved meaning may have had only auto_replace set.
-- Retain that decision when it becomes a multi-meaning group, without inventing a default.
with previous as (
 select public.intelkb_alias_key(d.trigger) key,min(d.id::text)::uuid id
 from public.intelkb_dictionary d
 where d.status='approved' and not exists(select 1 from intelkb_bundled_approval e where e.id=d.id)
 and public.intelkb_alias_key(d.trigger) in (select public.intelkb_alias_key(w.trigger) from public.intelkb_dictionary w join intelkb_bundled_approval e on e.id=w.id where e.managed and e.published_id is null)
 group by public.intelkb_alias_key(d.trigger) having count(*)=1
), desired as (
 select d.id,
 not exists(select 1 from public.intelkb_dictionary p where p.status='approved' and public.intelkb_alias_key(p.trigger)=v.key and p.auto_direct)
 and (d.category='profanity' or not exists(select 1 from public.intelkb_dictionary p where p.status='approved' and public.intelkb_alias_key(p.trigger)=v.key and p.category='profanity')) as direct,
 d.category<>'profanity' and not exists(select 1 from public.intelkb_dictionary p where p.status='approved' and public.intelkb_alias_key(p.trigger)=v.key and p.auto_gentle) as gentle
 from previous v join public.intelkb_dictionary d on d.id=v.id where d.auto_replace
)
update public.intelkb_dictionary d set auto_direct=d.auto_direct or v.direct,auto_gentle=d.auto_gentle or v.gentle,
 revision=d.revision+1,updated_at=now()
from desired v where d.id=v.id and ((v.direct and not d.auto_direct) or (v.gentle and not d.auto_gentle));
commit;
`;
}
