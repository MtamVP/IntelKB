-- IntelKB community workflow. Run this migration, then the seed SQL, as project owner.
begin;
create table if not exists public.intelkb_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.intelkb_admins enable row level security;
revoke all on public.intelkb_admins from anon, authenticated;

create or replace function public.intelkb_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.intelkb_admins where user_id = (select auth.uid()));
$$;
revoke all on function public.intelkb_is_admin() from public;
grant execute on function public.intelkb_is_admin() to anon, authenticated;

create table if not exists public.intelkb_dictionary (
  id uuid primary key default gen_random_uuid(),
  trigger text not null check(char_length(trigger) between 1 and 48),
  expansion text not null check(char_length(expansion) between 1 and 240),
  category text not null check(category in ('chat','profanity','euphemism','english','game')),
  auto_replace boolean not null default false,
  status text not null default 'draft' check(status in ('draft','approved','rejected')),
  revision integer not null default 1,
  source text not null default 'community' check(source in ('bootstrap','community')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists intelkb_approved_pair_idx on public.intelkb_dictionary(lower(trigger),lower(expansion)) where status='approved';
alter table public.intelkb_dictionary enable row level security;
revoke all on public.intelkb_dictionary from anon, authenticated;
grant select(id,trigger,expansion,category,auto_replace,status,revision,source,created_at,updated_at) on public.intelkb_dictionary to anon;
grant select on public.intelkb_dictionary to authenticated;
drop policy if exists intelkb_catalogue_read on public.intelkb_dictionary;
create policy intelkb_catalogue_read on public.intelkb_dictionary for select to anon, authenticated
using(status='approved' or public.intelkb_is_admin());

create table if not exists public.intelkb_proposals (
  id uuid primary key default gen_random_uuid(),
  receipt uuid not null unique,
  action text not null check(action in ('new','add_meaning','edit')),
  target_id uuid references public.intelkb_dictionary(id),
  base_revision integer,
  trigger text not null check(char_length(trigger) between 1 and 48),
  expansion text not null check(char_length(expansion) between 1 and 240),
  category text not null check(category in ('chat','profanity','euphemism','english','game')),
  auto_replace boolean not null default false,
  explanation text not null default '' check(char_length(explanation)<=1000),
  contributor_name text not null default '' check(char_length(contributor_name)<=60),
  status text not null default 'pending' check(status in ('pending','accepted','rejected')),
  moderator_note text not null default '',
  moderated_by uuid references auth.users(id),
  moderated_at timestamptz,
  accepted_entry_id uuid references public.intelkb_dictionary(id),
  created_at timestamptz not null default now(),
  constraint intelkb_target_shape check((action='new' and target_id is null and base_revision is null) or (action<>'new' and target_id is not null and base_revision is not null))
);
create index if not exists intelkb_proposal_queue_idx on public.intelkb_proposals(status,created_at);
create unique index if not exists intelkb_pending_proposal_unique on public.intelkb_proposals(action,coalesce(target_id,'00000000-0000-0000-0000-000000000000'::uuid),lower(trigger),lower(expansion)) where status='pending';
alter table public.intelkb_proposals enable row level security;
revoke all on public.intelkb_proposals from anon, authenticated;
grant select on public.intelkb_proposals to authenticated;
drop policy if exists intelkb_proposal_admin_read on public.intelkb_proposals;
create policy intelkb_proposal_admin_read on public.intelkb_proposals for select to authenticated using(public.intelkb_is_admin());

create or replace function public.intelkb_submit_proposal(
  p_receipt uuid, p_action text, p_trigger text, p_expansion text, p_category text,
  p_auto_replace boolean default false, p_target_id uuid default null, p_base_revision integer default null,
  p_explanation text default '', p_contributor_name text default ''
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_target public.intelkb_dictionary; v_existing public.intelkb_proposals; v_id uuid;
  v_trigger text := lower(regexp_replace(btrim(normalize(p_trigger,NFC)),'\s+',' ','g'));
  v_expansion text := regexp_replace(btrim(normalize(p_expansion,NFC)),'\s+',' ','g');
begin
  if p_receipt is null or p_action not in ('new','add_meaning','edit') or p_action is null then raise exception 'Invalid proposal'; end if;
  if p_action <> 'new' then
    select * into v_target from public.intelkb_dictionary where id=p_target_id and status='approved';
    if not found then raise exception 'Target no longer available'; end if;
    if p_base_revision is distinct from v_target.revision then raise exception 'Entry changed; reload before suggesting'; end if;
    v_trigger := v_target.trigger;
  elsif p_target_id is not null or p_base_revision is not null then raise exception 'New proposal cannot replace an existing entry';
  end if;
  if v_trigger is null or char_length(v_trigger) not between 1 and 48 or v_expansion is null or char_length(v_expansion) not between 1 and 240
    or p_category is null or p_category not in ('chat','profanity','euphemism','english','game') or v_trigger=lower(v_expansion)
    or char_length(coalesce(p_explanation,''))>1000 or char_length(coalesce(p_contributor_name,''))>60 then raise exception 'Invalid word or meaning'; end if;
  select * into v_existing from public.intelkb_proposals where receipt=p_receipt;
  if found then
    if v_existing.action<>p_action or v_existing.trigger<>v_trigger or v_existing.expansion<>v_expansion
      or v_existing.target_id is distinct from p_target_id or v_existing.base_revision is distinct from p_base_revision
      or v_existing.category is distinct from p_category or v_existing.auto_replace is distinct from coalesce(p_auto_replace,false)
      or v_existing.explanation is distinct from coalesce(p_explanation,'') or v_existing.contributor_name is distinct from coalesce(p_contributor_name,'') then raise exception 'Receipt already used'; end if;
    return jsonb_build_object('id',v_existing.id,'status',v_existing.status);
  end if;
  if exists(select 1 from public.intelkb_proposals where status='pending' and action=p_action and trigger=v_trigger and expansion=v_expansion and target_id is not distinct from p_target_id) then
    raise exception 'An identical proposal is already pending';
  end if;
  insert into public.intelkb_proposals(receipt,action,target_id,base_revision,trigger,expansion,category,auto_replace,explanation,contributor_name)
  values(p_receipt,p_action,p_target_id,p_base_revision,v_trigger,v_expansion,p_category,coalesce(p_auto_replace,false),coalesce(p_explanation,''),coalesce(p_contributor_name,'')) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','pending');
end; $$;
revoke all on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) from public;
grant execute on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) to anon, authenticated;

create or replace function public.intelkb_review_proposal(p_id uuid,p_decision text,p_note text default '',p_override jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_proposal public.intelkb_proposals; v_target public.intelkb_dictionary; v_entry uuid;
  v_trigger text; v_expansion text; v_category text; v_auto boolean;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('accept','reject') or char_length(coalesce(p_note,''))>1000 then raise exception 'Invalid decision'; end if;
  select * into v_proposal from public.intelkb_proposals where id=p_id for update;
  if not found or v_proposal.status<>'pending' then raise exception 'Proposal already processed or not found'; end if;
  if p_decision='accept' then
    v_trigger := v_proposal.trigger;
    v_expansion := coalesce(p_override->>'expansion',v_proposal.expansion);
    v_category := coalesce(p_override->>'category',v_proposal.category);
    v_auto := coalesce((p_override->>'auto_replace')::boolean,v_proposal.auto_replace);
    v_expansion := regexp_replace(btrim(normalize(v_expansion,NFC)),'\s+',' ','g');
    if char_length(v_expansion) not between 1 and 240 or lower(v_expansion)=lower(v_trigger) then raise exception 'Invalid accepted meaning'; end if;
    if v_proposal.action<>'new' then
      select * into v_target from public.intelkb_dictionary where id=v_proposal.target_id for update;
      if not found or v_target.status<>'approved' or v_target.revision<>v_proposal.base_revision then raise exception 'Entry changed since proposal; reload or reject this stale proposal'; end if;
    end if;
    if v_proposal.action='edit' then
      update public.intelkb_dictionary set expansion=v_expansion,category=v_category,auto_replace=v_auto,revision=revision+1,
        reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=v_target.id returning id into v_entry;
    else
      insert into public.intelkb_dictionary(trigger,expansion,category,auto_replace,status,source,reviewed_by,reviewed_at)
      values(v_trigger,v_expansion,v_category,v_auto,'approved','community',auth.uid(),now()) returning id into v_entry;
    end if;
  end if;
  update public.intelkb_proposals set status=case when p_decision='accept' then 'accepted' else 'rejected' end,
    moderator_note=coalesce(p_note,''),moderated_by=auth.uid(),moderated_at=now(),accepted_entry_id=v_entry where id=p_id;
  return jsonb_build_object('id',p_id,'status',case when p_decision='accept' then 'accepted' else 'rejected' end,'entry_id',v_entry);
end; $$;
revoke all on function public.intelkb_review_proposal(uuid,text,text,jsonb) from public;
grant execute on function public.intelkb_review_proposal(uuid,text,text,jsonb) to authenticated;

create or replace function public.intelkb_review_seed(p_id uuid,p_decision text,p_revision integer,p_override jsonb default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_row public.intelkb_dictionary;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  select * into v_row from public.intelkb_dictionary where id=p_id for update;
  if not found or v_row.status<>'draft' or v_row.revision<>p_revision then raise exception 'Seed already processed or changed'; end if;
  if p_decision is null or p_decision not in ('accept','reject') then raise exception 'Invalid decision'; end if;
  update public.intelkb_dictionary set status=case when p_decision='accept' then 'approved' else 'rejected' end,
    expansion=coalesce(p_override->>'expansion',expansion),category=coalesce(p_override->>'category',category),
    auto_replace=coalesce((p_override->>'auto_replace')::boolean,auto_replace),
    reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now(),revision=revision+1 where id=p_id;
end; $$;
revoke all on function public.intelkb_review_seed(uuid,text,integer,jsonb) from public;
grant execute on function public.intelkb_review_seed(uuid,text,integer,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

-- Initial editorial candidates: owner must review each before public use.
begin;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bd528c3a-cc2e-52da-be94-5e920b681ad3','ae','anh em','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1d55f504-53c1-5769-a1ad-685cb9c4a993','asap','as soon as possible','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d4920df8-eddd-5810-a381-f992eb7f579f','b','bạn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('25842be0-5bc0-5a7a-98f3-d694cc7770cd','baoh','bao giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e261911c-182f-5a88-930f-9f127f4b6f02','bb','bạn bè','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('afc58a9e-7f71-5dea-a776-cbdc291893bb','bb','tạm biệt','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('536e04dc-0906-5d85-a334-fe1ec551b748','bg','bây giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5fbfedcc-b74d-52ba-9a95-70a80cebb78d','bgio','bây giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c8ec6fc7-193c-590e-a4b7-2c9658d3e215','bh','bao giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8a36b615-71a4-5a28-9eca-6031fd9dca1b','bh','bây giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('97381d1b-e149-59eb-a37a-f985f485f51f','bik','biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('23f808be-86c5-57b1-9f06-92b5507cfda9','bjt','biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d8b61072-b07c-57f7-b8bd-9a127bcf50bf','bn','bao nhiêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2e1f02a5-aed9-5743-8556-54e75846608e','bn','bạn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('62e59fd5-6dff-55f4-bb01-fa653ed941ac','bsvv','buổi sáng vui vẻ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('cd39901d-6c88-5c3e-9f84-11bcf47a76cc','bt','bình thường','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9ee68e97-0793-5fba-b813-9da91d212e75','bth','bình thường','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8a03f664-1d87-5a07-ae01-74f7820025c6','btw','by the way','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('817449a7-dd1a-5c56-903c-5af85faf759d','bít','biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5d89176a-8cfb-56fc-af7e-cc7f510a7993','camon','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2e1b5cda-dd49-584c-b148-12bb76538055','chs','chẳng hiểu sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('690e58ab-5ecd-5bfa-b1af-d0228439c457','ck','chồng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('63babe77-a380-5168-bdb4-a959df70a125','clmm','cái lồn mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d9ebff72-335d-5d03-b583-e66e9c8ffe57','cmm','con mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a672db18-a64f-5afe-8522-79a4106797e3','cmn','con mẹ nó','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('349d6368-a60e-57a6-b179-7ae97674cc5d','cmnr','chuẩn mẹ nó rồi','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e615e726-f2f0-5d7d-be3f-fadeab92a1b3','cmnr','con mẹ nó rồi','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('be217c45-9105-57c0-ba76-f6a8c862f8be','cmsn','chúc mừng sinh nhật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('56fcd0f1-7045-58cf-8880-46c67065e675','cty','công ty','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5cf82e4d-a0fa-54fe-82c1-81324445393f','cv','công việc','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b1264e02-c7c2-5fef-a304-b097be9c9e7b','cx','cũng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('04f3f86a-9cea-5762-ba46-4996f2bc481b','cám ơn','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('67a2be54-e952-5f04-83d1-5dd3129a9aa4','cũg','cũng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('21a4a5f1-81dc-5005-98c0-2fc22ab86125','dbh','đéo bao giờ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a5ff57dc-97dd-5825-829d-f4ce1b8a1bee','dc','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6b6bd970-9f18-5b2b-92c5-0525b344d2d2','dcm','địt con mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e2dd5062-30cb-587d-b3b1-56eefdc2d3ed','dcmm','địt con mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e9841d98-806b-5819-b7ff-c1d2f4d47891','dhs','đéo hiểu sao','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b354ce9d-b81c-539c-90f1-bf37d81f0241','dk','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('cec7a90a-7f72-5492-9748-3e7dee27d2e9','dm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('42cde413-6457-548d-a320-5f1471730004','dm','đụ má','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('386b7116-3378-57be-b7ba-1a1f25533285','dmm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b2ecb160-2008-59fb-9a09-0cc8f25453a7','dmm','địt mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2c5e20ae-041e-5a72-941d-d55d678f8cd5','dr','đúng rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f1031991-d36e-543d-bda9-144d3de11b29','dt','dễ thương','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('71e448b0-83d9-5ed7-8b5a-2dac7425932b','dt','điện thoại','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9bbf39e4-ab57-57a7-b528-426bd55b1c29','dth','dễ thương','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d46b430a-8164-5c0a-ac81-6cbb4ac3357f','dthw','dễ thương','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('289ccc73-5d7f-59a6-9831-2bc756ed6054','dị','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9575472a-7462-5388-b522-ef7a9d0a4d4b','fyi','for your information','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1c5110ae-b735-5f0a-961d-148236889c91','hgl','hẹn gặp lại','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('97feff20-0ed7-5e43-a36d-f45b677a4856','hk','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9d828ff5-0760-5aae-8dc8-656292d553d4','hn','hôm nay','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e94d45fc-26e8-53f3-a572-edc8d6a79e44','hnay','hôm nay','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a82f4a25-25fd-5004-9b15-a4f4ace0e743','hok','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b59c42ca-1608-5a65-8be5-ad7e05d07ab2','hong','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('25453026-33db-5e41-91d2-2c1b3b04ebdc','hpbd','chúc mừng sinh nhật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('36fd6b8d-fd28-56ef-be7c-be547708ed9c','hq','hôm qua','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4ce83990-49f2-52d7-a203-f1874621fee4','hqua','hôm qua','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('89f4536c-7fdd-5931-8c49-f71c60f57b97','hs','học sinh','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e555c9c9-4013-58e8-8be8-7e3961245965','hông','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('62bcd5ab-4d31-5a7a-8976-29f6f7bd7f96','in4','thông tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fe2bc002-4e4f-5a60-8ac8-78e610473d18','info','thông tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fe383f8a-022a-5f96-b8f3-72df6e26c04a','iu','yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ea41b720-009b-5692-b15b-f249b9af3158','j','gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6639cd77-eeed-56e2-8ad0-911b81402f9f','ji','gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('31635bca-13b7-5a14-be62-f7154c8264b3','k','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d1b9c88b-6f8d-5c3b-a27a-36a9101e8a85','k sao','không sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('33787478-1f15-5809-ab94-3169e21552a9','k0','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('912c07fd-87ab-5a78-84f6-c8e442bb171c','kb','không biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b34cc8bf-7995-57b1-8d41-7ddef7bbe5e0','kb','kết bạn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('493e1e80-1090-59dd-bb1c-122687b3f649','kbt','không biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2f0a76bd-3a9c-5b34-86ba-e3f0e5f7c45c','kh','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8b2a6598-7b1c-5dbf-a64d-907eaf85f8c1','khum','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('116aec1b-37be-5e20-a002-768806cdd9b1','klq','không liên quan','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4b3606be-1a44-5d0f-b1aa-ac91e093d96e','ko','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ec94439f-72cc-5a30-9214-c8eb5d48b7d7','ks','không sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('16f68797-89ff-59b8-a4bb-98098e1f61fc','ksao','không sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('dc3e669c-b575-58ae-baf5-23ed7acbe83d','kô','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('33228a0f-81a2-5f44-9093-37a85283c9f4','lmht','liên minh huyền thoại','game','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d51cccc4-d309-59f4-b951-421ee81263b7','lol','League of Legends','game','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('20103932-7929-5090-bd78-a6c01f6709fc','lol','laughing out loud','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('62e5a899-fcb4-50e6-b8b9-6b9b5b416af1','lol','lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8071b622-e40e-5b85-8ab8-8fa11c07ef86','loz','lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3ff196ab-9b13-560e-8c1d-25103f0776da','lozz','lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e71920fe-b558-54b2-a6b0-3a0b8a4e0a9b','lq','liên quân','game','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6da02a16-d52d-5754-bfb8-4f7d31228552','lz','lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c544785d-bb62-502c-8993-da250d593523','m','mày','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2d8f2107-8cae-5fd0-b387-671d01f46b3c','mik','mình','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b1f794ff-84bb-5170-a660-42ce771e2a07','mjh','mình','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a57759cc-99d1-5081-a49d-69e11a14fa7b','mk','mình','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('00c27705-2b1d-5938-8153-f50318ddb276','mk','mật khẩu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8c890fbb-7597-58d3-a540-315c8f044559','mn','mọi người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ed960969-65e6-5c88-b559-2317b6d4b8aa','mng','mọi người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5d4a753c-69ac-5654-a651-0c353003da14','mngười','mọi người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9f75f419-52d8-5b2c-b3f9-05e0ce7934b7','nc','nói chuyện','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a6956308-4fe2-56ea-a877-f6a23877fa6e','nch','nói chuyện','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2cdc95f5-f99d-504d-a0d9-d34651b73941','ngta','người ta','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('cd1b0ecf-adf5-51d5-a64d-0b937af3b67c','ngyeu','người yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('836e9d92-3c8e-57f1-9006-ccf8c7c58e19','nt','nhắn tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a28c42fe-0490-5c38-8ad6-c6b18cb7a10e','nt','nói thật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('231223ae-b183-51f3-bb2d-d8e59beb491b','nta','người ta','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a3b59727-cc7c-5dd6-9346-feb73d2a8881','nthe','như thế','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('23f983b2-fe4d-56c0-84dd-9a3bcaaed3ec','ntn','như thế nào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f86b3746-c469-51b0-b2a5-ebb502e30df6','ntnao','như thế nào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4276f423-8cae-5e2d-95df-20c7be71c22b','ny','người yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('35111946-c369-5895-ab8c-b1ab0dc53a2c','nyc','người yêu cũ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('da130068-a2d0-54fc-b07d-449cad7c262b','ok','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2db165bb-c895-5593-bda9-c3f7b85d7ad1','oke','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e7b1c65e-29df-5967-afda-a25eaafcf237','okela','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a2845280-9fd8-59fb-ab64-00fa6f49b226','oki','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2aecae47-2149-5d56-953e-66eae7b07c27','okie','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('76fac0a4-fa03-52b3-9c1d-e14f536d60c7','omg','oh my god','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e5ea532b-bf61-564d-be9f-0309fc41f773','oy','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bbfcc672-0d0c-59b6-ac7f-b624833ec11e','pp','tạm biệt','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f8562eb9-1c87-54e2-8f15-5baa7cb23e21','r','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6dace73d-0c30-59e1-a249-44fd8fb8d45e','rùi','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('33134108-b5ba-59a1-8321-020b498d1e03','sdt','số điện thoại','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('16bd8168-a5b2-578d-b6c7-1eaabf5066ad','sml','sấp mặt luôn','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('26ad20dd-4b82-522d-9c3b-9b009441f830','sml','sấp mặt lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6a9935f1-cc43-5192-98c6-7d25df6467c9','sorry','xin lỗi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b30561d4-5ba0-5bc2-ba79-68bad2989aab','sr','xin lỗi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('02598c3a-3731-5afa-8fb5-b13d1bc86b22','sry','xin lỗi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('55f42a8f-1758-500a-8072-12dcb1e3645d','stk','số tài khoản','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('43839860-87cf-5ca2-bde2-d109851c8ce6','sv','sinh viên','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('795164a4-f862-53f8-b0cc-f96d8261dd7d','sđt','số điện thoại','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1913e6aa-16dc-5b8a-bdd5-3c9bb198f313','t','tao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c938f952-e4e7-510d-baf3-3b07539daa31','t','tôi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5e6d525d-a56f-56f1-a7ac-21c15535ca05','t','tớ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6974418d-e430-5d29-8071-533fd54dc787','tdn','thế đéo nào','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('42feee98-4e4d-55a9-9030-95734b124b42','thank','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('85e76ea8-5d53-5ed8-836e-89004748317d','thanks','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4520a339-74b5-5f0f-bec8-4b2606e6de03','thik','thích','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1ca9057b-910d-547b-a355-30e5a9c381da','thjk','thích','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('29b13377-9407-5be1-9d8a-098a217a29ca','thx','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bf04c89a-877a-5d0a-9c8e-8ea21af1133f','tks','cảm ơn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5034aaa9-7d52-537a-90df-e140e9173f66','tl','trả lời','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b3f5b1e6-2154-5709-847b-0a2cfdc18d5c','tn','thế nào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d644f056-60af-5976-aa0f-a42a91be3b1d','tnào','thế nào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('164cbde1-2b3d-5d5e-bddc-99929f6efddd','ts','tại sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1d85a1d2-54f6-5661-b8cc-099196e88908','tsao','tại sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b801289c-483e-5c13-b184-9c53f226966c','tv','tại vì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2d1413eb-f5c5-5f62-bf32-a44d33c28552','tđn','thế đéo nào','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('80c20d8b-e047-5c59-a262-40bd25686927','v','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6a182c2f-c1bd-533d-aee3-68a2555df5a9','vc','vãi chưởng','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('eeab017d-dc5f-52c7-b653-88047d45af4f','vc','vợ chồng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d45e4c5d-2cde-5012-8404-adf346257ad8','vcc','vãi cả cặc','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e478f104-6cb4-57ed-b120-c21cad360891','vcd','vãi cả đái','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('cf55e0e7-f550-5f63-9f55-b87494042cfa','vch','vãi chưởng','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ce3dcd3b-0b25-542e-bcc3-e4635559576a','vchg','vãi chưởng','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2fe06177-eea1-5aee-8ccc-dfb38a1dffe5','vcl','vãi cả lúa','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b72aaadc-6753-5a28-9fcc-2cd71889b398','vcl','vãi cả lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7295a445-0fa7-520e-b3b6-e26e3fe65fbb','vcđ','vãi cả đái','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('14aa7ab8-5dae-569d-bed9-904ecd38e7a7','vd','vãi đái','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4b74401a-29dd-58f9-a24e-f276b5dd7cc5','vk','vợ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b42b6e7c-54f9-5f97-bf6a-f10ec352109d','vkl','vãi cả lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9e13702c-3ca7-50e9-b5a7-4f08feeb9933','vkll','vãi cả lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b1aca791-c65f-5b15-bb66-5b45c7af9be6','vl','vãi lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e2c5efae-99cf-57e2-9ba2-ffd455dd88a5','vll','vãi lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('80d41b16-eee2-53ae-b3b5-b15968f80234','vs','với','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('003ac6d4-b271-5dde-abba-56fb168081ee','vđ','vãi đái','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('62b35de0-16bc-536e-9135-cebd7ad060aa','wtf','what the fuck','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0bf524c4-11a2-544a-abce-a24641d5ecf5','xl','xin lỗi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1e6f5824-5d5e-50f3-b033-367741504000','xl','xạo lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('40a04009-7cfb-5c4d-a8c3-ba8f4655990d','xlone','xạo lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('772c2b8b-45d0-5f6a-90be-bf8345c5ac99','z','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8513bb3f-37a9-557c-b057-99fff55d6b2b','zi','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('dbc59cd0-c883-5038-bf3f-d2ba1ee06500','zậy','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('68da9130-c1c0-549b-a6d2-e86a7ddb0e90','òi','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4cd432b3-8b59-5af2-862c-ef9a45e50681','òy','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5d702f79-78a1-5be2-9330-2a05f33552a6','đag','đang','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0ed1970f-8ffb-5755-914c-5447a344c9e4','đbh','đéo bao giờ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3db227d2-1f10-5331-87de-a006b97d590f','đc','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5482b36e-04b3-5379-94d4-8406e25065ea','đcm','địt con mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9e38e3c1-9d67-5200-9087-c6557fe6865c','đcmm','địt con mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2f8789ea-1d15-55bd-8cc3-0bb538e516e1','đhs','đéo hiểu sao','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('46f2b0ef-e547-583c-914e-da1c7df206db','đk','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5985d68b-ea61-5036-94a3-d47754739030','đm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d591058d-e3cf-5904-a3b9-d01f41969e07','đm','đụ má','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a8d109da-671e-54df-af21-e86cdc6878f0','đmm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a37de7f5-7e0b-54f9-b9cc-c9a059b9502d','đmm','địt mẹ mày','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d2aca031-a95b-5510-acce-e8e555301037','đr','đúng rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('662137ad-1b67-5dda-a626-28d28f7a7ade','đt','điện thoại','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f454365e-f967-5c2c-a5e5-1d9622bc2bc2','hem','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('09a0ebf3-c089-57a9-9e37-6294fe853e95','hăm','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c8ab4202-3f50-5127-bddd-0e60ad011e27','khg','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7e751e80-4804-5e41-afb6-a58db2f23eca','khôg','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('20e47d8e-38f9-599f-81ae-c4a76af5cf45','khong','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('41d93c51-5a4c-549c-80e8-b3fded96de85','khôngg','không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('91f97ca0-4794-5cc8-849a-06fef5b42fe5','kphai','không phải','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2c4b9c03-948b-5f73-a868-43699f9d6e71','kph','không phải','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('00bf0f78-e2ae-53c8-a1cd-bc0f6b9c4273','k phải','không phải','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d8a5e662-369b-5131-a82c-f8700489e448','kco','không có','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1a17b62f-8154-52a5-904c-4a5ec7a76ef8','k có','không có','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7dfdbb6c-b72a-5bd8-a11a-58d2dcef20be','khbt','không biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ee436cdc-f15f-5684-be5f-f2c0da85684f','kbiet','không biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2060c740-7c12-59cf-a21c-4c8465e45caf','k biết','không biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e123328c-476b-5aae-9412-1d174105560d','ch','chưa','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('99aa560a-152c-5843-b3a4-ede7896a2f30','ckua','chưa','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2ff090a3-b51b-5bf1-ac53-99f747140a64','chbt','chưa biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d7840f3d-a68c-53d4-86d8-508039cd9944','cbt','chưa biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a9e0b263-251e-548b-8b21-fc33dca4fbb8','đx','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('29c73329-d902-573d-9e25-1a4fb02b624d','duoc','được','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ae5d90fe-38d3-5e5a-b1ba-af64e287e0c2','biet','biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('efaf02db-0d91-5ef3-9fce-73caef540c0d','bík','biết','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3510fcf2-9bd7-55ff-aedd-4d381837e63b','vay','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('288d182d-3d5d-5218-92f8-5a88f7cbd4cc','dậy','vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d62d0f03-accb-5ea3-8fff-c3f0c63331e1','ròi','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ebfe5a8f-a167-5c56-a72b-a6db775dea0a','roii','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('923613b8-840f-5ce2-9524-ac08e56e4751','ròii','rồi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5af33744-3718-5c5e-8e6c-7007ebbd9dd6','gi','gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a684bcdf-0d46-57f9-9f30-23d62a034c49','jz','gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('132fe8e8-62dd-5033-a0a4-09dcbcacef44','cgì','cái gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b13f6ea4-2685-5730-82da-3bc3046a909f','cj','cái gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5a8a8e6c-333a-575b-b049-9e3ed6bdaf8c','cgi','cái gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5f645f4c-2a65-5654-8c2c-5e877511719f','lgi','làm gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a75edbef-5a2e-5270-820f-e394dc88267b','lmgi','làm gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d23acfb1-03b7-5329-8238-43a125d3b374','lmj','làm gì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9ad837be-e159-5ecf-bafd-565bffe13edd','lsao','làm sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3b81b67d-0c59-53fb-8690-4bd6b589be02','lmsao','làm sao','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ee0428a7-a753-590a-b455-9b072daf063f','tg','thế giới','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1495dd51-4c81-5507-b677-1e01f1647691','tg','thời gian','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d1dcd355-2290-5816-9af0-d88300716c96','tgian','thời gian','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9377081f-fb2a-51b2-b9ee-3ebf2842591c','thgian','thời gian','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8f404533-a83c-5803-92d7-fec13ca06508','bnh','bao nhiêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d568ede4-9a1f-526b-ad6c-c31bb3592b2e','bnhiu','bao nhiêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f78b64cf-2983-5a9d-9d77-458b3ae80238','bgiờ','bao giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bbed30e6-bae5-5ab9-ba67-cb70b8668f65','bjo','bây giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('70cc7b86-e875-57bc-ae52-f27cb208617c','bgiờ','bây giờ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2aa20232-4dd4-562e-8d2b-d4f0a5bb5a94','lnao','lúc nào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e19fdfdf-d224-56c8-96c4-585d8f887bbd','ngmai','ngày mai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fc6d8b6b-3aed-527a-bbac-3f1e4b8199aa','nmai','ngày mai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('587b5d0f-c6e9-5374-9d0a-9bc80fc24614','nghqua','ngày hôm qua','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c7069a4e-be08-5c95-9454-236d9927a278','homnay','hôm nay','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('728c0ac4-78c1-5d74-9de3-94d53c89d24e','homqua','hôm qua','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f9b4167a-69ad-5354-a87e-2d027c738ac5','tsau','tuần sau','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('74cf1c13-8751-5709-ab07-d92677300a6b','ttrc','tuần trước','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0cedcad7-3e07-5108-90eb-59535f9102d3','trc','trước','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b73fbf93-df43-5106-bd7f-d3891946ce65','trướcc','trước','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9c3afd54-5608-59d0-a39a-48643de3d019','sauu','sau','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8c1732de-80a8-5dba-ad8c-3ac943a85cc5','xg','xong','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b9a99cee-7660-5ac6-8de6-ac2defe187f4','xog','xong','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('883b1deb-6366-52b0-a44c-a48afc5c8ea0','xg','xuống','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5e193d64-4019-5ce6-bc53-5801d976cff0','tht','thật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7ad5f67a-56c8-513c-80bf-6a71b4b828da','thậtt','thật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5082515f-f69b-5f94-86fc-286217d27ccb','ths','thật sự','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3112a706-8423-5a5a-a8d2-41001c363259','thsu','thật sự','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3d183595-92bc-5d7b-aec5-61358be70fc7','thra','thật ra','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c0f14023-f7b2-5ba8-b09a-d510f7f84757','nthật','nói thật','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8c6f2888-6741-53b1-9e47-850448f8dc66','đko','đúng không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('dafc95dd-75d6-51f0-9f69-89e802bd4c05','dko','đúng không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('83219f88-0245-5800-bd37-15906c71eca7','đk','đúng không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c7924359-8a4b-5319-8ebf-16e87101b1b0','dk','đúng không','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('77575c7b-61ee-52c5-9427-ecb378a66414','đv','đúng vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e9672cb0-992d-527d-adc5-9e3308a137b7','dv','đúng vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4d2ac27c-3ef8-564e-8959-305fadc0b362','đk','đăng ký','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('25f0cbab-d780-5dbb-9d92-e736bcbe4a39','dk','đăng ký','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b06671c8-64fe-5bcf-b758-6fe80496873e','dky','đăng ký','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5ef3478c-432f-5f94-b11e-fc74c569e8b8','đky','đăng ký','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c3d6e752-3eca-5d3f-997f-97d9a616f80b','bl','bình luận','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('13a62283-75a0-5f48-8977-e1c5d9a53cb0','cmt','bình luận','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b488f83f-6cf5-5421-ab84-5c368ba8573f','tn','tin nhắn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('29e435d7-0b01-59d8-bbf9-e83a0970a723','ntin','nhắn tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9d8d4756-469d-53bd-8443-80eab0585cda','nhantin','nhắn tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6ac4d345-1f0c-59d3-acab-24583324c63c','ib','nhắn tin riêng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('02b4193b-378c-5402-8689-4525c2692e94','inbox','nhắn tin riêng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('57a483a4-0e8e-52b3-b268-baff23253ef5','ibx','nhắn tin riêng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5b2c3a72-23c4-5f43-814a-a881686043fc','trloi','trả lời','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0be46daa-c19c-5532-a2a0-233f5619c8ce','rep','trả lời','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c9d48092-e4e9-5386-b02d-47647c61c8ce','tk','tài khoản','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0ca84dfd-681c-5a7b-b2f9-40a13973e9b8','ng','người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1b6b37ad-eac7-5156-8832-13ec4d15459e','ngừi','người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('453faadf-4e5c-5228-a6ef-306d50f0c811','ngấy','người ấy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d26ad0dd-7ae4-56ec-b9d2-faf01cb470ab','ngiu','người yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9e7f1060-d765-5762-8790-a8275c111f9a','btrai','bạn trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f4766cd4-5e54-5774-b3e8-b267fb6dbfd3','bf','bạn trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e7956fc3-8579-58f0-921c-3269b587c0da','bgai','bạn gái','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5a01cfd7-b20b-5b7f-b3a4-e96ff629acfe','bgái','bạn gái','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a00adb07-b501-56e3-a8cb-e99836c2991c','gf','bạn gái','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c5559b8e-99a2-5ecd-b14e-b65c8bbf8f8a','atrai','anh trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3d1fe084-a052-5471-90d6-583b43a274a9','cgai','chị gái','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('846a4112-ec5d-51ed-be72-d5489c81d9a9','egai','em gái','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c536fad9-4101-55c3-8735-3f08ea8f1687','bme','bố mẹ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('147a17b4-0af4-5c05-b823-d77be3defd61','bm','bố mẹ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f0ebf88a-2182-5ace-9f53-333409e7c0b5','cnha','cả nhà','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('21aeb67d-e2b0-5d83-b971-367e71e95225','c2','cả hai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a74395fd-1845-51fd-a32f-46eb469a3844','cả 2','cả hai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7daecd06-f8c3-59e4-8faa-6c906b600b0e','cb','các bạn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5917a23a-6e1f-5498-be17-7d2a97a9bd17','mọi ng','mọi người','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a7b05554-480e-507f-bfaf-878ebd715b28','cta','chúng ta','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('641a7e8b-0925-5604-b109-3bd4a12ab60d','chta','chúng ta','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('99bd956f-8315-5ee1-8796-685f3b9b7454','cmik','chúng mình','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ffed7973-cce9-5934-9571-25ca35246db5','aye','anh yêu em','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('579dbb58-29ce-56ef-82d5-46cfde31cc49','eya','em yêu anh','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d1a0a50c-8b0e-5516-8501-1ba9c199baf6','dthuong','dễ thương','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f7f06abf-396b-5ae4-9746-5db512517a0b','dthương','dễ thương','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('71c97b23-9997-5a9e-8f44-c96c433e716e','đz','đẹp trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('41c85663-bb37-50da-9a31-79bcd8cfdca8','đzai','đẹp trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a8d3bcc6-3fab-54e2-b4ec-0e431297acca','dz','đẹp trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5d91ddac-bd5d-5e16-b395-383c2b53d1ba','dzai','đẹp trai','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f6c2a3a5-e3e9-56ab-97d9-7bb1e1c83060','dy','đáng yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('aa8e291c-8707-5bda-83bf-c2d8f65ae4fc','đy','đáng yêu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('748c3cc0-371e-5fe3-814b-616cc802dda8','vv','vui vẻ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9b28d4be-42e2-5151-bd87-35ad415a975b','hp','hạnh phúc','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9656e0b3-3aaa-52ad-94ed-5fe615380296','hphuc','hạnh phúc','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1f279858-5852-5134-8e8b-2fb641f085c5','hphúc','hạnh phúc','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7ab46512-cf7a-548b-8230-3d4402f8f741','qt','quan tâm','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('58927ea3-9381-580a-99e3-177e9b599f1a','qtam','quan tâm','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ccb86b63-11a0-5219-9e25-6f5b5b0d7437','qtâm','quan tâm','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('38e7af56-e5fb-56df-980d-85527f81ccf3','qtrong','quan trọng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('63134e05-f957-5034-9efb-0c9b85312e68','qtr','quan trọng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('36b7f922-6d1c-555b-a5a2-932efffd8ad7','cg','cố gắng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ce1a7e75-8e61-5cec-b164-48592bfb73eb','cgắng','cố gắng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2145cf2d-4aad-5ecb-a58f-783dfa42bc66','ktra','kiểm tra','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('3e6cece2-efc7-59e8-b82b-33d9423c271b','kt','kiểm tra','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('dc02f48f-6af4-56c8-aabd-2ba14fc09020','bt','bài tập','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4562c395-9df9-5a09-9b08-a337aa024ef8','btap','bài tập','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('55519e46-9588-5bd2-b921-fb09334d21e2','btvn','bài tập về nhà','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('330cb679-7534-5036-911c-364d700a7434','hb','học bài','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e48d56cc-0e67-53b3-8929-f7beff105a44','hk','học kỳ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fd02cae6-d030-5daa-83f1-d92f99ea3166','hkì','học kỳ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bf8542b9-a9d7-5fee-8fba-1f7b2ea514f7','gv','giáo viên','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('cf3867b2-117d-5727-b72a-255f097bf33f','trhoc','trường học','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('efdc42b7-7a2c-5b55-840c-6e8b371c74b6','đh','đại học','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f99ef5d1-3953-5134-b86c-0708cf6d7406','dh','đại học','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f327768e-1408-5ea9-9593-0856fb7277be','thpt','trung học phổ thông','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4cca5df5-5d94-51b0-a365-55f077a053d8','thcs','trung học cơ sở','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9874d181-c0fd-54a8-9f0d-3c677271594b','cntt','công nghệ thông tin','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('31eaf9ec-8d68-5d2b-b169-95ecbaf43c04','pv','phỏng vấn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6f1d0660-3085-514f-a701-88d39ff6a435','lv','làm việc','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('60bbee65-bc53-55fe-b025-51092e4327d4','nv','nhân viên','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0ef55ec5-433f-59f1-a058-2cba17bcf32f','kh','khách hàng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2362c478-9f72-5145-ac55-a89c60e15f15','sp','sản phẩm','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('befa85c7-6d9b-50e3-803f-c43f8d3b8d42','dv','dịch vụ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('42b15d3d-df5d-5fbd-8b9e-0fd17ee0766a','hđ','hợp đồng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('90d43c70-cab3-5bee-a03c-980b87ed0ee0','hd','hợp đồng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2bb7c24b-7ebc-59fa-9f27-da876fa8ca1a','hd','hướng dẫn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('841ab2ba-84dc-5a51-865c-380fb5a82c1a','tb','thông báo','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2436b7ed-a085-50d3-9b3c-5e6be9007b81','vd','ví dụ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a8fc3ccf-5e0e-53f8-843a-6add72a4a0c5','vdu','ví dụ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('da3ffdbd-270e-5d56-af5b-83d0d6dee45b','vđ','vấn đề','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('ebb0cfd5-d76f-5b4b-b14e-dcb068a62204','vde','vấn đề','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('02044af4-f115-5b11-80c8-e9b91b9c7641','vđề','vấn đề','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fad5d969-c8c9-564e-85fb-ea7118e17cf6','bv','bởi vì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fca53af0-1f01-57e6-aa7e-3f435c9e9ca0','vv','vì vậy','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9a47191e-f6f7-543a-9585-d28a54318149','tn','tuy nhiên','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('beb1a8b5-a7e6-52c8-85fd-c888cfb18f12','nc','nói chung','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('373c1b79-bb70-5c84-9d4c-71ce08440574','nchung','nói chung','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8686b48e-440d-539e-a574-65e0bfc90d20','lq','liên quan','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2026032d-019c-51d2-a4cd-ec45de33545b','lquan','liên quan','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('dc27f5be-68d1-5b30-bbb8-fecaf2e6f1b2','khieu','không hiểu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5f611918-d8a9-5799-b1ef-1a431e1648dc','k hiểu','không hiểu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('fd4427f7-497d-5343-9eab-3371922a5c8e','đy','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('5c11fdea-d34d-54be-869b-7416b6e39e60','dy','đồng ý','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('16208e8f-d718-592a-8279-e86d13bcc550','tt','từ từ','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('8cecf542-f801-59ea-93c2-598064fcce4f','tt','trung tâm','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('52975f59-4d06-5418-83dc-f961aaab4bba','lun','liền','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('70f75d53-2048-5fe5-9bde-e20b01126554','lun','luôn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('556b4d76-7f46-5498-9673-befaf18b266a','luon','luôn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c80fdf76-a8cf-5be0-ad4a-15672986d1d2','nx','nữa','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('50912be3-1515-51a6-80c0-19675c6a2205','nữaa','nữa','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('33f45e55-3979-59dc-99bd-ceb4479b8be5','cừi','cười','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1231f599-b06e-5f90-a43d-2ec770a4ec08','bùn','buồn','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c61ad5fb-b9a3-57c1-950c-c1b1fa2e595e','thui','thôi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2a17d9fa-a62a-5dc0-8c7f-5d5ac19decbd','thoy','thôi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('572e379c-93bf-5f47-999d-7200b14bd082','thoi','thôi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f984bdb3-d7b2-5558-bcc9-c52d03d5dd47','hoy','thôi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d729bd76-f8a0-5d1a-b3dd-8ef4da2260d0','đii','đi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('0e9fde86-a242-57a1-9364-f3502fbfd0a5','dii','đi','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('f5bafc12-4d4a-5e1f-9f58-c9716f8bda80','đou','đâu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('64719a78-9caa-586e-b4db-01e0b7be8510','dou','đâu','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('bb6d8f5c-bbbd-57e6-8d78-391d768f86b0','đei','đây','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6ceac617-58f0-5757-9868-c49cdec81832','dei','đây','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d590ed32-e35d-5050-addc-82e115a89dba','zô','vào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('78980fce-6722-5ce0-a32e-ff3ce94c39ec','zo','vào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9ddeb053-8c18-5fa4-8991-9dea81eb7dbe','zề','về','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('7149cd6d-199e-53c3-8238-d83f38d641d4','ze','về','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b5259b37-159e-5742-9d99-a3c483579b05','ms','mới','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e05cca24-15f7-5607-9963-809454e75983','thíck','thích','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('59d1175c-d1d8-5d0e-b9aa-16fa56c365eb','thich','thích','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('71e54bca-9cc8-5bf9-b2d4-a27920afdf72','nhg','nhưng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('53f2f695-47b1-5d20-8e31-99d91ba99544','nhưg','nhưng','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('df571843-33ab-50e4-89f4-d12136a1753c','nhìu','nhiều','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('77cc82be-6d7e-5534-befb-bf0781664ed7','nhiu','nhiều','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('59edf565-afac-5c71-b15c-14f6bcced7eb','wa','quá','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4825c34f-eeca-5eb4-867a-ab225bf3eba1','wá','quá','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('19434809-20f5-5f6e-8942-82a0307280ab','qá','quá','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4e690307-0d72-54a7-98bd-c6e09f5718e2','rấtt','rất','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('400c518b-b27a-5e13-896d-09fbc81f0739','tvi','tại vì','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('585443c7-9f73-5e5c-a45d-a75f6387cc0c','helo','xin chào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6363d0d6-b67d-54a5-8197-f3e031ed7832','hello','xin chào','chat','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('9169ee96-ad40-5c49-9901-5bf5d231a95b','tbh','to be honest','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('a1e85f83-b2cd-542a-b85c-1a30079c7da9','imo','in my opinion','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2c8c7ca1-3d3c-5083-a2ec-7b5f1f17f63d','idk','I do not know','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('494c5ea2-4004-5afb-bfa4-4938809152e4','brb','be right back','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e6d81afc-3d33-5411-95a0-ea25c5cfcb0b','dm','direct message','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('229bb652-a5aa-52a6-b3fa-7e48ac335a4f','pm','private message','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('085e15cf-b07a-511a-86cf-4c51f13d7709','gg','good game','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2675130d-47ab-5744-9fa5-0acfc4c00758','gn','good night','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('438467a4-351a-58a0-a2a3-d4627ca0ee79','g9','good night','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('510e62b5-585f-5123-bdeb-0766e16cdabb','gl','good luck','english','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('b209773b-3690-55af-94fe-cc28bf42307a','đkm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('eb2d004b-585a-5de6-9353-3fa6ffafad5b','dkm','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('642af443-d63c-53fe-9622-cf583e7265e8','dume','địt mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('41c818a0-c887-5a8d-9328-1de18044d4ea','cl','cái lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('2cb0d889-ddff-5a23-88b7-050defa3518c','cc','cái cặc','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6da1216d-eb2d-5899-bef3-3fa10aa5fcf1','éo','đéo','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('06418725-1e1f-5f9b-ace0-630ca2f284a5','deo','đéo','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('1a71ea11-a525-598b-849d-c234bc1a04a5','del','đéo','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('841a32e5-93e9-5478-8201-fbdadc5529fc','dell','đéo','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('d3e55ac6-a9ff-501f-b742-3be8cc7d7b5d','đhieu','đéo hiểu','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6e892c73-ed96-5428-bfc8-00dedd6bb348','deohieu','đéo hiểu','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('6dcf3de0-9db9-511b-a408-f78680b91979','clm','cái lồn mẹ','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('e61b704b-1e84-5354-8e28-fdb7258a18b4','đuma','đụ má','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('4c2686cf-65bc-5fe4-81bb-887d9a491717','duma','đụ má','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('edf160ff-bc84-5c04-8a82-57a46d25ac92','vler','vãi lồn','profanity','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('30345f45-1b5b-5111-912e-032e403dc5dd','vchưởng','vãi chưởng','euphemism','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('32ef1c97-ad87-552d-85b8-3985952ff337','lqm','liên quân mobile','game','draft','bootstrap') on conflict(id) do nothing;
insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('c8321950-195b-5c0b-bc76-d18178de2414','dtcl','đấu trường chân lý','game','draft','bootstrap') on conflict(id) do nothing;
commit;

-- IntelKB contribution checks and compact bulk-review workbench.
-- Run AFTER 20261017_community_moderation.sql. Does not depend on optional P0 drafts.
begin;
create or replace function public.intelkb_pair_key(p_trigger text,p_expansion text) returns text
language sql immutable set search_path='' as $$
 select lower(btrim(regexp_replace(normalize(coalesce(p_trigger,''),NFC),'\s+',' ','g'))) || chr(31) ||
 lower(btrim(regexp_replace(normalize(coalesce(p_expansion,''),NFC),'\s+',' ','g')));
$$;
revoke all on function public.intelkb_pair_key(text,text) from public;

create or replace function public.intelkb_check_pair(p_trigger text,p_expansion text,p_exclude_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if char_length(coalesce(p_trigger,'')) not between 1 and 48 or char_length(coalesce(p_expansion,'')) not between 1 and 240 then
   return jsonb_build_object('match','none'); end if;
 if exists(select 1 from public.intelkb_dictionary where status='approved' and id is distinct from p_exclude_id
   and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(p_trigger,p_expansion)) then
   return jsonb_build_object('match','published'); end if;
 -- Return only existence for this exact supplied pair, never queue content or identities.
 if exists(select 1 from public.intelkb_proposals where status='pending'
   and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(p_trigger,p_expansion)) then
   return jsonb_build_object('match','pending'); end if;
 return jsonb_build_object('match','none');
end; $$;
revoke all on function public.intelkb_check_pair(text,text,uuid) from public;
grant execute on function public.intelkb_check_pair(text,text,uuid) to anon,authenticated;

create or replace function public.intelkb_submit_proposal(
  p_receipt uuid, p_action text, p_trigger text, p_expansion text, p_category text,
  p_auto_replace boolean default false, p_target_id uuid default null, p_base_revision integer default null,
  p_explanation text default '', p_contributor_name text default ''
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_target public.intelkb_dictionary; v_existing public.intelkb_proposals; v_id uuid;
  v_trigger text := lower(regexp_replace(btrim(normalize(p_trigger,NFC)),'\s+',' ','g'));
  v_expansion text := regexp_replace(btrim(normalize(p_expansion,NFC)),'\s+',' ','g');
begin
  if p_receipt is null or p_action not in ('new','add_meaning','edit') or p_action is null then raise exception 'Invalid proposal'; end if;
  if p_action <> 'new' then
    select * into v_target from public.intelkb_dictionary where id=p_target_id and status='approved';
    if not found then raise exception 'Target no longer available'; end if;
    if p_base_revision is distinct from v_target.revision then raise exception 'Entry changed; reload before suggesting'; end if;
    v_trigger := v_target.trigger;
  elsif p_target_id is not null or p_base_revision is not null then raise exception 'New proposal cannot replace an existing entry';
  end if;
  if v_trigger is null or char_length(v_trigger) not between 1 and 48 or v_expansion is null or char_length(v_expansion) not between 1 and 240
    or p_category is null or p_category not in ('chat','profanity','euphemism','english','game') or v_trigger=lower(v_expansion)
    or char_length(coalesce(p_explanation,''))>1000 or char_length(coalesce(p_contributor_name,''))>60 then raise exception 'Invalid word or meaning'; end if;
  select * into v_existing from public.intelkb_proposals where receipt=p_receipt;
  if found then
    if v_existing.action<>p_action or v_existing.trigger<>v_trigger or v_existing.expansion<>v_expansion
      or v_existing.target_id is distinct from p_target_id or v_existing.base_revision is distinct from p_base_revision
      or v_existing.category is distinct from p_category or v_existing.auto_replace is distinct from coalesce(p_auto_replace,false)
      or v_existing.explanation is distinct from coalesce(p_explanation,'') or v_existing.contributor_name is distinct from coalesce(p_contributor_name,'') then raise exception 'Receipt already used'; end if;
    return jsonb_build_object('id',v_existing.id,'status',v_existing.status);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(public.intelkb_pair_key(v_trigger,v_expansion),0));
  if exists(select 1 from public.intelkb_dictionary where status='approved'
    and (p_action<>'edit' or id is distinct from p_target_id)
    and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(v_trigger,v_expansion)) then
    raise exception 'Word and meaning already published' using errcode='23505';
  end if;
  if exists(select 1 from public.intelkb_proposals where status='pending' and action=p_action
    and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(v_trigger,v_expansion)
    and target_id is not distinct from p_target_id) then
    raise exception 'An identical proposal is already pending';
  end if;
  insert into public.intelkb_proposals(receipt,action,target_id,base_revision,trigger,expansion,category,auto_replace,explanation,contributor_name)
  values(p_receipt,p_action,p_target_id,p_base_revision,v_trigger,v_expansion,p_category,coalesce(p_auto_replace,false),coalesce(p_explanation,''),coalesce(p_contributor_name,'')) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','pending');
end; $$;
revoke all on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) from public;
grant execute on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) to anon, authenticated;


create or replace function public.intelkb_review_queue(
 p_kind text default 'proposals',p_status text default 'pending',p_search text default '',p_category text default '',
 p_offset integer default 0,p_limit integer default 50,p_grouped boolean default true
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('seeds','proposals') or p_status is null or p_status not in ('pending','accepted','rejected') then raise exception 'Invalid queue filter'; end if;
 with entries as (
   select to_jsonb(d) as data,d.id,d.trigger,d.expansion,d.category,d.status,d.created_at from public.intelkb_dictionary d where p_kind='seeds'
   union all
   select to_jsonb(p),p.id,p.trigger,p.expansion,p.category,p.status,p.created_at from public.intelkb_proposals p where p_kind='proposals'
 ), filtered as (
   select * from entries where status=case when p_kind='seeds' then case p_status when 'pending' then 'draft' when 'accepted' then 'approved' else 'rejected' end else p_status end
   and (coalesce(p_category,'')='' or category=p_category)
   and (coalesce(p_search,'')='' or position(lower(btrim(normalize(p_search,NFC))) in lower(trigger||' '||expansion))>0)
 ), page as (
   select * from filtered order by case when p_grouped then lower(trigger) else '' end,created_at,id
   limit greatest(1,least(coalesce(p_limit,50),100)) offset greatest(0,coalesce(p_offset,0))
 ) select jsonb_build_object('rows',coalesce((select jsonb_agg(data order by case when p_grouped then lower(trigger) else '' end,created_at,id) from page),'[]'::jsonb),
 'total',(select count(*) from filtered),
 'counts',jsonb_build_object('seeds',(select count(*) from public.intelkb_dictionary where status='draft'),
 'proposals',(select count(*) from public.intelkb_proposals where status='pending'),
 'approved',(select count(*) from public.intelkb_dictionary where status='approved'))) into v_result;
 return v_result;
end; $$;
revoke all on function public.intelkb_review_queue(text,text,text,text,integer,integer,boolean) from public;
grant execute on function public.intelkb_review_queue(text,text,text,text,integer,integer,boolean) to authenticated;

create table if not exists public.intelkb_review_log(
 id uuid primary key default gen_random_uuid(),entry_id uuid not null,kind text not null,decision text not null,
 note text not null default '',reviewer uuid not null references auth.users(id),created_at timestamptz not null default now()
);
alter table public.intelkb_review_log enable row level security;
revoke all on public.intelkb_review_log from anon,authenticated;
grant select on public.intelkb_review_log to authenticated;
drop policy if exists intelkb_review_log_admin on public.intelkb_review_log;
create policy intelkb_review_log_admin on public.intelkb_review_log for select to authenticated using(public.intelkb_is_admin());

create or replace function public.intelkb_review_batch(p_items jsonb,p_decision text,p_note text default '',p_options jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb;result jsonb;results jsonb:='[]'::jsonb;override jsonb;entry uuid;current_revision integer;ok integer:=0;failed integer:=0;
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Items must be an array'; end if;
 if jsonb_array_length(p_items) not between 1 and 100 or p_decision is null or p_decision not in ('accept','reject') or char_length(coalesce(p_note,''))>1000 then raise exception 'Invalid batch'; end if;
 if p_options is not null and jsonb_typeof(p_options)<>'object' then raise exception 'Invalid options'; end if;
 if coalesce(p_options,'{}'::jsonb) ? 'auto_replace' and (p_options->'auto_replace') is distinct from 'false'::jsonb then raise exception 'Batch can only disable automatic replacement'; end if;
 for item in select * from jsonb_array_elements(p_items) loop
   begin
     entry:=(item->>'id')::uuid;
     override:=coalesce(item->'override','{}'::jsonb)||coalesce(p_options,'{}'::jsonb);
     if item->>'kind'='seeds' then
       select revision into current_revision from public.intelkb_dictionary where id=entry for update;
       if current_revision is distinct from (item->>'revision')::integer then raise exception 'Entry changed; reload before reviewing'; end if;
       perform public.intelkb_review_seed(entry,p_decision,current_revision,override);
     elsif item->>'kind'='proposals' then
       perform public.intelkb_review_proposal(entry,p_decision,coalesce(p_note,''),override);
     else raise exception 'Invalid item kind'; end if;
     insert into public.intelkb_review_log(entry_id,kind,decision,note,reviewer) values(entry,item->>'kind',p_decision,coalesce(p_note,''),auth.uid());
     ok:=ok+1;result:=jsonb_build_object('id',item->>'id','ok',true);
   exception when others then
     failed:=failed+1;result:=jsonb_build_object('id',item->>'id','ok',false,'error',sqlerrm);
   end;
   results:=results||jsonb_build_array(result);
 end loop;
 return jsonb_build_object('ok',ok,'failed',failed,'rows',results);
end; $$;
revoke all on function public.intelkb_review_batch(jsonb,text,text,jsonb) from public;
grant execute on function public.intelkb_review_batch(jsonb,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

-- Full-entry duplicate checks. Run after 20261018_review_tools.sql. No data is deleted.
begin;
create or replace function public.intelkb_check_entry(p_trigger text,p_expansion text,p_category text,p_auto_replace boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if char_length(coalesce(p_trigger,'')) not between 1 and 48
   or char_length(coalesce(p_expansion,'')) not between 1 and 240
   or p_category is null or p_category not in ('chat','profanity','euphemism','english','game') then
   return jsonb_build_object('match','none');end if;
 if exists(select 1 from public.intelkb_dictionary where status='approved'
   and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(p_trigger,p_expansion)
   and category=p_category and auto_replace=coalesce(p_auto_replace,false)) then return jsonb_build_object('match','published');end if;
 if exists(select 1 from public.intelkb_proposals where status='pending'
   and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(p_trigger,p_expansion)
   and category=p_category and auto_replace=coalesce(p_auto_replace,false)) then return jsonb_build_object('match','pending');end if;
 return jsonb_build_object('match','none');
end;$$;
revoke all on function public.intelkb_check_entry(text,text,text,boolean) from public;
grant execute on function public.intelkb_check_entry(text,text,text,boolean) to anon,authenticated;
-- Broaden the previous index to allow distinct category / automatic filling proposals.
drop index if exists public.intelkb_pending_proposal_unique;
create unique index intelkb_pending_proposal_unique on public.intelkb_proposals(action,coalesce(target_id,'00000000-0000-0000-0000-000000000000'::uuid),lower(trigger),lower(expansion),category,auto_replace) where status='pending';

create or replace function public.intelkb_submit_proposal(
  p_receipt uuid, p_action text, p_trigger text, p_expansion text, p_category text,
  p_auto_replace boolean default false, p_target_id uuid default null, p_base_revision integer default null,
  p_explanation text default '', p_contributor_name text default ''
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_target public.intelkb_dictionary; v_existing public.intelkb_proposals; v_id uuid; v_action text:=p_action; v_target_id uuid:=p_target_id; v_base_revision integer:=p_base_revision;
  v_trigger text := lower(regexp_replace(btrim(normalize(p_trigger,NFC)),'\s+',' ','g'));
  v_expansion text := regexp_replace(btrim(normalize(p_expansion,NFC)),'\s+',' ','g');
begin
  if p_receipt is null or p_action not in ('new','add_meaning','edit') or p_action is null then raise exception 'Invalid proposal'; end if;
  -- Keep the original receipt valid after approval and revision changes.
  select * into v_existing from public.intelkb_proposals where receipt=p_receipt;
  if found then
    if (v_existing.action<>p_action and not(p_action='new' and v_existing.action='edit'))
      or public.intelkb_pair_key(v_existing.trigger,v_existing.expansion)<>public.intelkb_pair_key(v_trigger,v_expansion)
      or (p_action<>'new' and (v_existing.target_id is distinct from p_target_id or v_existing.base_revision is distinct from p_base_revision))
      or v_existing.category is distinct from p_category or v_existing.auto_replace is distinct from coalesce(p_auto_replace,false)
      or v_existing.explanation is distinct from coalesce(p_explanation,'') or v_existing.contributor_name is distinct from coalesce(p_contributor_name,'') then raise exception 'Receipt already used'; end if;
    return jsonb_build_object('id',v_existing.id,'status',v_existing.status);
  end if;
  if p_action <> 'new' then
    select * into v_target from public.intelkb_dictionary where id=p_target_id and status='approved';
    if not found then raise exception 'Target no longer available'; end if;
    if p_base_revision is distinct from v_target.revision then raise exception 'Entry changed; reload before suggesting'; end if;
    if p_action='add_meaning' then v_trigger:=lower(regexp_replace(btrim(normalize(v_target.trigger,NFC)),'\s+',' ','g')); end if;
  elsif p_target_id is not null or p_base_revision is not null then raise exception 'New proposal cannot replace an existing entry';
  end if;
  if v_trigger is null or char_length(v_trigger) not between 1 and 48 or v_expansion is null or char_length(v_expansion) not between 1 and 240
    or p_category is null or p_category not in ('chat','profanity','euphemism','english','game') or v_trigger=lower(v_expansion)
    or char_length(coalesce(p_explanation,''))>1000 or char_length(coalesce(p_contributor_name,''))>60 then raise exception 'Invalid word or meaning'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(public.intelkb_pair_key(v_trigger,v_expansion),0));
  if exists(select 1 from public.intelkb_dictionary where status='approved'
    and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(v_trigger,v_expansion)
    and category=p_category and auto_replace=coalesce(p_auto_replace,false)) then
    raise exception 'All entry information already published; No changes' using errcode='23505';
  end if;
  -- A matching pair with different metadata edits the published row instead of creating a duplicate.
  if v_action in ('new','add_meaning') then
    select * into v_target from public.intelkb_dictionary where status='approved'
      and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(v_trigger,v_expansion);
    if found then v_action:='edit';v_target_id:=v_target.id;v_base_revision:=v_target.revision; end if;
  end if;
  if exists(select 1 from public.intelkb_proposals where status='pending'
    and public.intelkb_pair_key(trigger,expansion)=public.intelkb_pair_key(v_trigger,v_expansion)
    and category=p_category and auto_replace=coalesce(p_auto_replace,false)) then
    raise exception 'An identical proposal is already pending';
  end if;
  insert into public.intelkb_proposals(receipt,action,target_id,base_revision,trigger,expansion,category,auto_replace,explanation,contributor_name)
  values(p_receipt,v_action,v_target_id,v_base_revision,v_trigger,v_expansion,p_category,coalesce(p_auto_replace,false),coalesce(p_explanation,''),coalesce(p_contributor_name,'')) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','pending');
end; $$;
revoke all on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) from public;
grant execute on function public.intelkb_submit_proposal(uuid,text,text,text,text,boolean,uuid,integer,text,text) to anon, authenticated;
create or replace function public.intelkb_review_proposal(p_id uuid,p_decision text,p_note text default '',p_override jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_proposal public.intelkb_proposals; v_target public.intelkb_dictionary; v_entry uuid;
  v_trigger text; v_expansion text; v_category text; v_auto boolean;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('accept','reject') or char_length(coalesce(p_note,''))>1000 then raise exception 'Invalid decision'; end if;
  select * into v_proposal from public.intelkb_proposals where id=p_id for update;
  if not found or v_proposal.status<>'pending' then raise exception 'Proposal already processed or not found'; end if;
  if p_decision='accept' then
    v_trigger := v_proposal.trigger;
    v_expansion := coalesce(p_override->>'expansion',v_proposal.expansion);
    v_category := coalesce(p_override->>'category',v_proposal.category);
    v_auto := coalesce((p_override->>'auto_replace')::boolean,v_proposal.auto_replace);
    v_expansion := regexp_replace(btrim(normalize(v_expansion,NFC)),'\s+',' ','g');
    if char_length(v_expansion) not between 1 and 240 or lower(v_expansion)=lower(v_trigger) then raise exception 'Invalid accepted meaning'; end if;
    if v_proposal.action<>'new' then
      select * into v_target from public.intelkb_dictionary where id=v_proposal.target_id for update;
      if not found or v_target.status<>'approved' or v_target.revision<>v_proposal.base_revision then raise exception 'Entry changed since proposal; reload or reject this stale proposal'; end if;
    end if;
    if v_proposal.action='edit' then
      update public.intelkb_dictionary set trigger=v_trigger,expansion=v_expansion,category=v_category,auto_replace=v_auto,revision=revision+1,
        reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=v_target.id returning id into v_entry;
    else
      insert into public.intelkb_dictionary(trigger,expansion,category,auto_replace,status,source,reviewed_by,reviewed_at)
      values(v_trigger,v_expansion,v_category,v_auto,'approved','community',auth.uid(),now()) returning id into v_entry;
    end if;
  end if;
  update public.intelkb_proposals set status=case when p_decision='accept' then 'accepted' else 'rejected' end,
    moderator_note=coalesce(p_note,''),moderated_by=auth.uid(),moderated_at=now(),accepted_entry_id=v_entry where id=p_id;
  return jsonb_build_object('id',p_id,'status',case when p_decision='accept' then 'accepted' else 'rejected' end,'entry_id',v_entry);
end; $$;
revoke all on function public.intelkb_review_proposal(uuid,text,text,jsonb) from public;
grant execute on function public.intelkb_review_proposal(uuid,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

-- Owner-chosen defaults per messaging mode, reversible review batches, and context for diffs.
-- Run after 20261018_entry_changes.sql. No published data is deleted.
begin;
create or replace function public.intelkb_alias_key(value text) returns text language sql immutable set search_path='' as $$
 select lower(btrim(regexp_replace(normalize(coalesce(value,''),NFC),'\s+',' ','g')));$$;
revoke all on function public.intelkb_alias_key(text) from public;
alter table public.intelkb_dictionary add column if not exists auto_direct boolean not null default false;
alter table public.intelkb_dictionary add column if not exists auto_gentle boolean not null default false;
grant select(auto_direct,auto_gentle) on public.intelkb_dictionary to anon;
create unique index if not exists intelkb_one_direct on public.intelkb_dictionary(public.intelkb_alias_key(trigger)) where status='approved' and auto_direct;
create unique index if not exists intelkb_one_gentle on public.intelkb_dictionary(public.intelkb_alias_key(trigger)) where status='approved' and auto_gentle;
create table if not exists public.intelkb_review_actions(
 id uuid primary key default gen_random_uuid(),receipt uuid not null unique,actor uuid not null references auth.users(id),
 aliases text[] not null,proposal_ids uuid[] not null,payload jsonb not null,before_state jsonb not null,after_state jsonb not null,
 report jsonb not null,created_at timestamptz not null default now(),undone_at timestamptz
);
alter table public.intelkb_review_actions enable row level security;
revoke all on public.intelkb_review_actions from anon,authenticated;
grant select on public.intelkb_review_actions to authenticated;
drop policy if exists intelkb_actions_owner on public.intelkb_review_actions;
create policy intelkb_actions_owner on public.intelkb_review_actions for select to authenticated using(public.intelkb_is_admin() and actor=auth.uid());
create or replace function public.intelkb_review_snapshot(keys text[],proposals uuid[]) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('d',coalesce((select jsonb_agg(to_jsonb(d) order by d.id) from public.intelkb_dictionary d where public.intelkb_alias_key(d.trigger)=any(keys)),'[]'::jsonb),
 'p',coalesce((select jsonb_agg(to_jsonb(p) order by p.id) from public.intelkb_proposals p where p.id=any(proposals)),'[]'::jsonb));$$;
revoke all on function public.intelkb_review_snapshot(text[],uuid[]) from public;
create or replace function public.intelkb_resolve_style(key text,preferred_direct uuid default null,preferred_gentle uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare total integer;pc integer;gc integer;dc integer;d uuid:=preferred_direct;g uuid:=preferred_gentle;changed uuid[];
begin
 select count(*),count(*) filter(where category='profanity'),count(*) filter(where category<>'profanity') into total,pc,gc
 from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key;
 dc:=case when pc>0 then pc else gc end;
 if d is not null and not exists(select 1 from public.intelkb_dictionary where id=d and status='approved' and public.intelkb_alias_key(trigger)=key and (case when pc>0 then category='profanity' else category<>'profanity' end)) then raise exception 'Invalid direct default for %',key;end if;
 if g is not null and not exists(select 1 from public.intelkb_dictionary where id=g and status='approved' and public.intelkb_alias_key(trigger)=key and category<>'profanity') then raise exception 'Invalid gentle default for %',key;end if;
 if total>1 then
  if dc=1 then select id into d from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key and (case when pc>0 then category='profanity' else category<>'profanity' end);
  elsif d is null then select id into d from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key and auto_direct and (case when pc>0 then category='profanity' else category<>'profanity' end);end if;
  if gc=1 then select id into g from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key and category<>'profanity';
  elsif g is null then select id into g from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key and auto_gentle and category<>'profanity';end if;
  if pc=0 then d:=coalesce(d,g);g:=coalesce(g,d);end if;
  if dc>1 and d is null then raise exception 'Choose direct default for %',key;end if;
  if gc>1 and g is null then raise exception 'Choose gentle default for %',key;end if;
 end if;
 select coalesce(array_agg(id),'{}'::uuid[]) into changed from public.intelkb_dictionary where status='approved' and public.intelkb_alias_key(trigger)=key
 and (auto_direct is distinct from coalesce(id=d,false) or auto_gentle is distinct from coalesce(id=g,false)
 or ((total>1 or d is not null or g is not null) and auto_replace is distinct from (coalesce(id=d,false) or coalesce(id=g,false))));
 update public.intelkb_dictionary set auto_direct=false,auto_gentle=false where id=any(changed);
 update public.intelkb_dictionary set auto_direct=coalesce(id=d,false),auto_gentle=coalesce(id=g,false),
 auto_replace=case when total>1 or d is not null or g is not null then coalesce(id=d,false) or coalesce(id=g,false) else auto_replace end,
 revision=revision+1,updated_at=now(),reviewed_by=coalesce(auth.uid(),reviewed_by),reviewed_at=now() where id=any(changed);
end;$$;
revoke all on function public.intelkb_resolve_style(text,uuid,uuid) from public;

-- Existing one-profane / one-safe pairs have an unambiguous default in both modes.
do $$declare group_row record;begin
 for group_row in select public.intelkb_alias_key(trigger) key from public.intelkb_dictionary where status='approved'
 group by public.intelkb_alias_key(trigger) having count(*)=2 and count(*) filter(where category='profanity')=1 loop
 perform public.intelkb_resolve_style(group_row.key);end loop;
end;$$;

create or replace function public.intelkb_review_context(p_items jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare keys text[];ids uuid[];
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid items';end if;
 if jsonb_array_length(p_items)>100 then raise exception 'Too many items';end if;
 select coalesce(array_agg((x->>'id')::uuid),'{}'::uuid[]) into ids from jsonb_array_elements(p_items) x;
 select array_agg(distinct q.key) into keys from (
 select public.intelkb_alias_key(d.trigger) key from public.intelkb_dictionary d where d.id=any(ids)
 union select public.intelkb_alias_key(p.trigger) from public.intelkb_proposals p where p.id=any(ids)
 union select public.intelkb_alias_key(d.trigger) from public.intelkb_dictionary d join public.intelkb_proposals p on p.target_id=d.id where p.id=any(ids)) q;
 return public.intelkb_review_snapshot(coalesce(keys,'{}'::text[]),'{}'::uuid[])->'d';
end;$$;
revoke all on function public.intelkb_review_context(jsonb) from public;
grant execute on function public.intelkb_review_context(jsonb) to authenticated;

create or replace function public.intelkb_review_proposal(p_id uuid,p_decision text,p_note text default '',p_override jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_proposal public.intelkb_proposals; v_target public.intelkb_dictionary; v_entry uuid;
  v_trigger text; v_expansion text; v_category text; v_auto boolean;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('accept','reject') or char_length(coalesce(p_note,''))>1000 then raise exception 'Invalid decision'; end if;
  select * into v_proposal from public.intelkb_proposals where id=p_id for update;
  if not found or v_proposal.status<>'pending' then raise exception 'Proposal already processed or not found'; end if;
  if p_decision='accept' then
    v_trigger := v_proposal.trigger;
    v_expansion := coalesce(p_override->>'expansion',v_proposal.expansion);
    v_category := coalesce(p_override->>'category',v_proposal.category);
    v_auto := coalesce((p_override->>'auto_replace')::boolean,v_proposal.auto_replace);
    v_expansion := regexp_replace(btrim(normalize(v_expansion,NFC)),'\s+',' ','g');
    if char_length(v_expansion) not between 1 and 240 or lower(v_expansion)=lower(v_trigger) then raise exception 'Invalid accepted meaning'; end if;
    if v_proposal.action<>'new' then
      select * into v_target from public.intelkb_dictionary where id=v_proposal.target_id for update;
      if not found or v_target.status<>'approved' or v_target.revision<>v_proposal.base_revision then raise exception 'Entry changed since proposal; reload or reject this stale proposal'; end if;
    end if;
    if v_proposal.action='edit' then
      update public.intelkb_dictionary set auto_direct=case when public.intelkb_alias_key(v_trigger)<>public.intelkb_alias_key(v_target.trigger) then false else auto_direct end,auto_gentle=case when public.intelkb_alias_key(v_trigger)<>public.intelkb_alias_key(v_target.trigger) then false else auto_gentle end,trigger=v_trigger,expansion=v_expansion,category=v_category,auto_replace=v_auto,revision=revision+1,
        reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=v_target.id returning id into v_entry;
    else
      insert into public.intelkb_dictionary(trigger,expansion,category,auto_replace,status,source,reviewed_by,reviewed_at)
      values(v_trigger,v_expansion,v_category,v_auto,'approved','community',auth.uid(),now()) returning id into v_entry;
    end if;
  end if;
  update public.intelkb_proposals set status=case when p_decision='accept' then 'accepted' else 'rejected' end,
    moderator_note=coalesce(p_note,''),moderated_by=auth.uid(),moderated_at=now(),accepted_entry_id=v_entry where id=p_id;
  return jsonb_build_object('id',p_id,'status',case when p_decision='accept' then 'accepted' else 'rejected' end,'entry_id',v_entry);
end; $$;
revoke all on function public.intelkb_review_proposal(uuid,text,text,jsonb) from public;
grant execute on function public.intelkb_review_proposal(uuid,text,text,jsonb) to authenticated;

create or replace function public.intelkb_review_commit(p_receipt uuid,p_items jsonb,p_decision text,p_note text default '',p_options jsonb default '{}',p_choices jsonb default '[]') returns jsonb
language plpgsql security definer set search_path='' as $$
declare keys text[];ids uuid[];old public.intelkb_review_actions;payload jsonb;before_state jsonb;after_state jsonb;report jsonb;action_id uuid;
 key text;choice jsonb;item jsonb;entry uuid;d uuid;g uuid;success_ids uuid[];
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 if p_receipt is null or p_items is null or jsonb_typeof(p_items)<>'array' or p_choices is null or jsonb_typeof(p_choices)<>'array' then raise exception 'Invalid review';end if;
 if jsonb_array_length(p_items) not between 1 and 100 or jsonb_array_length(p_choices)>200 then raise exception 'Invalid batch size';end if;
 payload:=jsonb_build_object('items',p_items,'decision',p_decision,'note',p_note,'options',p_options,'choices',p_choices);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_receipt::text,31));
 select * into old from public.intelkb_review_actions where receipt=p_receipt;
 if found then if old.actor<>auth.uid() or old.payload<>payload then raise exception 'Receipt already used';end if;if old.undone_at is not null then raise exception 'Review already undone';end if;return old.report;end if;
 select coalesce(array_agg((x->>'id')::uuid),'{}'::uuid[]) into ids from jsonb_array_elements(p_items) x;
 select array_agg(distinct q.key order by q.key) into keys from (
 select public.intelkb_alias_key(trigger) key from public.intelkb_dictionary where id=any(ids)
 union select public.intelkb_alias_key(trigger) from public.intelkb_proposals where id=any(ids)
 union select public.intelkb_alias_key(d.trigger) from public.intelkb_dictionary d join public.intelkb_proposals p on p.target_id=d.id where p.id=any(ids)) q;
 keys:=coalesce(keys,'{}'::text[]);
 foreach key in array keys loop perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(key,71));end loop;
 perform 1 from public.intelkb_dictionary where public.intelkb_alias_key(trigger)=any(keys) order by id for update;
 perform 1 from public.intelkb_proposals where id=any(ids) order by id for update;
 before_state:=public.intelkb_review_snapshot(keys,ids);
 report:=public.intelkb_review_batch(p_items,p_decision,p_note,p_options);
 select coalesce(array_agg((r->>'id')::uuid),'{}'::uuid[]) into success_ids from jsonb_array_elements(report->'rows') r where (r->>'ok')::boolean;
 if p_decision='accept' and cardinality(success_ids)>0 then
  foreach key in array keys loop
   -- A failed item in an unrelated group must not block successful reviews.
   if (select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]'::jsonb) from public.intelkb_dictionary r where public.intelkb_alias_key(r.trigger)=key)
     =(select coalesce(jsonb_agg(b order by b->>'id'),'[]'::jsonb) from jsonb_array_elements(before_state->'d') b where public.intelkb_alias_key(b->>'trigger')=key) then continue;end if;
   d:=null;g:=null;
   for choice in select * from jsonb_array_elements(p_choices) loop
    if public.intelkb_alias_key(choice->>'trigger')<>key then continue;end if;
    if choice->>'kind'='approved' then entry:=(choice->>'id')::uuid;
    elsif (choice->>'id')::uuid=any(success_ids) then
     if choice->>'kind'='seeds' then entry:=(choice->>'id')::uuid;
     else select accepted_entry_id into entry from public.intelkb_proposals where id=(choice->>'id')::uuid;end if;
    else raise exception 'Default must be an approved or successfully reviewed entry';end if;
    if choice->>'mode'='direct' then if d is not null then raise exception 'Only one direct default';end if;d:=entry;
    elsif choice->>'mode'='gentle' then if g is not null then raise exception 'Only one gentle default';end if;g:=entry;
    else raise exception 'Invalid messaging mode';end if;
   end loop;
   perform public.intelkb_resolve_style(key,d,g);
  end loop;
 end if;
 after_state:=public.intelkb_review_snapshot(keys,ids);action_id:=gen_random_uuid();
 report:=report||jsonb_build_object('action_id',action_id,'undo_available',before_state<>after_state);
 insert into public.intelkb_review_actions(id,receipt,actor,aliases,proposal_ids,payload,before_state,after_state,report) values(action_id,p_receipt,auth.uid(),keys,ids,payload,before_state,after_state,report);
 return report;
end;$$;
revoke all on function public.intelkb_review_commit(uuid,jsonb,text,text,jsonb,jsonb) from public;
grant execute on function public.intelkb_review_commit(uuid,jsonb,text,text,jsonb,jsonb) to authenticated;

create or replace function public.intelkb_set_style_defaults(p_receipt uuid,p_trigger text,p_direct uuid default null,p_gentle uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare key text:=public.intelkb_alias_key(p_trigger);old public.intelkb_review_actions;payload jsonb;before_state jsonb;after_state jsonb;report jsonb;action_id uuid:=gen_random_uuid();
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 if p_receipt is null then raise exception 'Receipt required';end if;
 payload:=jsonb_build_object('trigger',key,'direct',p_direct,'gentle',p_gentle);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_receipt::text,31));
 select * into old from public.intelkb_review_actions where receipt=p_receipt;
 if found then if old.actor<>auth.uid() or old.payload<>payload or old.undone_at is not null then raise exception 'Receipt already used';end if;return old.report;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(key,71));
 perform 1 from public.intelkb_dictionary where public.intelkb_alias_key(trigger)=key order by id for update;
 before_state:=public.intelkb_review_snapshot(array[key],'{}'::uuid[]);
 perform public.intelkb_resolve_style(key,p_direct,p_gentle);
 after_state:=public.intelkb_review_snapshot(array[key],'{}'::uuid[]);
 report:=jsonb_build_object('action_id',action_id,'undo_available',before_state<>after_state,'ok',1,'failed',0,'rows','[]'::jsonb);
 insert into public.intelkb_review_actions(id,receipt,actor,aliases,proposal_ids,payload,before_state,after_state,report) values(action_id,p_receipt,auth.uid(),array[key],'{}',payload,before_state,after_state,report);
 return report;
end;$$;
revoke all on function public.intelkb_set_style_defaults(uuid,text,uuid,uuid) from public;
grant execute on function public.intelkb_set_style_defaults(uuid,text,uuid,uuid) to authenticated;

create or replace function public.intelkb_last_review() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report jsonb;
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 select jsonb_build_object('action_id',id,'undo_available',undone_at is null and before_state<>after_state) into report from public.intelkb_review_actions where actor=auth.uid() and before_state<>after_state order by created_at desc,id desc limit 1;
 return coalesce(report,'{}');end;$$;
revoke all on function public.intelkb_last_review() from public;
grant execute on function public.intelkb_last_review() to authenticated;

create or replace function public.intelkb_undo_review(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare action public.intelkb_review_actions;key text;row jsonb;old_row jsonb;changed uuid[];value public.intelkb_dictionary;proposal public.intelkb_proposals;
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 select * into action from public.intelkb_review_actions where id=p_id for update;
 if not found or action.actor<>auth.uid() then raise exception 'Review action not found';end if;
 if action.undone_at is not null then return jsonb_build_object('undone',true);end if;
 foreach key in array action.aliases loop perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(key,71));end loop;
 perform 1 from public.intelkb_dictionary where public.intelkb_alias_key(trigger)=any(action.aliases) order by id for update;
 perform 1 from public.intelkb_proposals where id=any(action.proposal_ids) order by id for update;
 if public.intelkb_review_snapshot(action.aliases,action.proposal_ids)<>action.after_state then raise exception 'Entries changed after this review; cannot overwrite newer changes';end if;
 select coalesce(array_agg((a->>'id')::uuid),'{}'::uuid[]) into changed from jsonb_array_elements(action.after_state->'d') a
 where not exists(select 1 from jsonb_array_elements(action.before_state->'d') b where b=a);
 -- Deactivate changed rows first so pair/default uniqueness holds during restoration.
 update public.intelkb_dictionary set status='rejected',auto_direct=false,auto_gentle=false,auto_replace=false,revision=revision+1,updated_at=now(),reviewed_by=coalesce(auth.uid(),reviewed_by),reviewed_at=now() where id=any(changed);
 for row in select * from jsonb_array_elements(action.before_state->'d') loop
  value:=jsonb_populate_record(null::public.intelkb_dictionary,row);
  if not(value.id=any(changed)) then continue;end if;
  update public.intelkb_dictionary set trigger=value.trigger,expansion=value.expansion,category=value.category,status=value.status,auto_replace=value.auto_replace,
   auto_direct=value.auto_direct,auto_gentle=value.auto_gentle,updated_at=now(),reviewed_by=auth.uid(),reviewed_at=now() where id=value.id;
 end loop;
 for row in select * from jsonb_array_elements(action.before_state->'p') loop
  if exists(select 1 from jsonb_array_elements(action.after_state->'p') a where a=row) then continue;end if;
  proposal:=jsonb_populate_record(null::public.intelkb_proposals,row);
  update public.intelkb_proposals set status=proposal.status,moderator_note=proposal.moderator_note,moderated_by=proposal.moderated_by,moderated_at=proposal.moderated_at,accepted_entry_id=proposal.accepted_entry_id,
   base_revision=case when proposal.action<>'new' and proposal.status='pending' and proposal.target_id=any(changed) and proposal.base_revision=(select (b->>'revision')::integer from jsonb_array_elements(action.before_state->'d') b where (b->>'id')::uuid=proposal.target_id) then (select revision from public.intelkb_dictionary where id=proposal.target_id) else proposal.base_revision end where id=proposal.id;
 end loop;
 update public.intelkb_review_actions set undone_at=now() where id=p_id;
 return jsonb_build_object('undone',true);
end;$$;
revoke all on function public.intelkb_undo_review(uuid) from public;
grant execute on function public.intelkb_undo_review(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- Approve untouched bundled words. Run after review-efficiency-upgrade.sql.
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
('ae','anh em','chat',true,true,true),
('asap','as soon as possible','english',false,false,false),
('atrai','anh trai','chat',false,false,false),
('aye','anh yêu em','chat',false,false,false),
('b','bạn','chat',false,false,false),
('baoh','bao giờ','chat',true,true,true),
('bb','bạn bè','chat',false,false,false),
('bb','tạm biệt','chat',false,false,false),
('bf','bạn trai','chat',false,false,false),
('bg','bây giờ','chat',false,false,false),
('bgai','bạn gái','chat',false,false,false),
('bgái','bạn gái','chat',false,false,false),
('bgio','bây giờ','chat',true,true,true),
('bgiờ','bao giờ','chat',false,false,false),
('bgiờ','bây giờ','chat',false,false,false),
('bh','bao giờ','chat',false,false,false),
('bh','bây giờ','chat',false,false,false),
('biet','biết','chat',false,false,false),
('bik','biết','chat',true,true,true),
('bík','biết','chat',false,false,false),
('bít','biết','chat',true,true,true),
('bjo','bây giờ','chat',false,false,false),
('bjt','biết','chat',true,true,true),
('bl','bình luận','chat',false,false,false),
('bm','bố mẹ','chat',false,false,false),
('bme','bố mẹ','chat',false,false,false),
('bn','bạn','chat',false,false,false),
('bn','bao nhiêu','chat',false,false,false),
('bnh','bao nhiêu','chat',false,false,false),
('bnhiu','bao nhiêu','chat',false,false,false),
('brb','be right back','english',false,false,false),
('bsvv','buổi sáng vui vẻ','chat',true,true,true),
('bt','bài tập','chat',false,false,false),
('bt','bình thường','chat',false,false,false),
('btap','bài tập','chat',true,true,true),
('bth','bình thường','chat',true,true,true),
('btrai','bạn trai','chat',false,false,false),
('btvn','bài tập về nhà','chat',true,true,true),
('btw','by the way','english',false,false,false),
('bùn','buồn','chat',true,true,true),
('bv','bởi vì','chat',false,false,false),
('c2','cả hai','chat',false,false,false),
('cả 2','cả hai','chat',false,false,false),
('cám ơn','cảm ơn','chat',false,false,false),
('camon','cảm ơn','chat',false,false,false),
('cb','các bạn','chat',false,false,false),
('cbt','chưa biết','chat',false,false,false),
('cc','cái cặc','profanity',false,false,false),
('cg','cố gắng','chat',false,false,false),
('cgai','chị gái','chat',false,false,false),
('cgắng','cố gắng','chat',true,true,true),
('cgi','cái gì','chat',false,false,false),
('cgì','cái gì','chat',false,false,false),
('ch','chưa','chat',false,false,false),
('chbt','chưa biết','chat',false,false,false),
('chs','chẳng hiểu sao','chat',true,true,true),
('chta','chúng ta','chat',false,false,false),
('cj','cái gì','chat',false,false,false),
('ck','chồng','chat',false,false,false),
('ckua','chưa','chat',false,false,false),
('cl','cái lồn','profanity',false,false,false),
('clm','cái lồn mẹ','profanity',false,false,false),
('clmm','cái lồn mẹ mày','profanity',true,true,false),
('cmik','chúng mình','chat',false,false,false),
('cmm','con mẹ mày','profanity',true,true,false),
('cmn','con mẹ nó','profanity',false,false,false),
('cmnr','chuẩn mẹ nó rồi','profanity',false,false,false),
('cmnr','con mẹ nó rồi','profanity',false,false,false),
('cmsn','chúc mừng sinh nhật','chat',true,true,true),
('cmt','bình luận','chat',false,false,false),
('cnha','cả nhà','chat',false,false,false),
('cntt','công nghệ thông tin','chat',false,false,false),
('cta','chúng ta','chat',false,false,false),
('cty','công ty','chat',true,true,true),
('cũg','cũng','chat',true,true,true),
('cừi','cười','chat',true,true,true),
('cv','công việc','chat',false,false,false),
('cx','cũng','chat',true,true,true),
('dậy','vậy','chat',false,false,false),
('dbh','đéo bao giờ','profanity',true,true,false),
('dc','được','chat',true,true,true),
('dcm','địt con mẹ','profanity',true,true,false),
('dcmm','địt con mẹ mày','profanity',true,true,false),
('dei','đây','chat',true,true,true),
('del','đéo','profanity',false,false,false),
('dell','đéo','profanity',false,false,false),
('deo','đéo','profanity',false,false,false),
('deohieu','đéo hiểu','profanity',false,false,false),
('dh','đại học','chat',false,false,false),
('dhs','đéo hiểu sao','profanity',true,true,false),
('dị','vậy','chat',false,false,false),
('dii','đi','chat',true,true,true),
('dk','đăng ký','chat',false,false,false),
('dk','đúng không','chat',false,false,false),
('dk','được','chat',false,false,false),
('dkm','địt mẹ','profanity',false,false,false),
('dko','đúng không','chat',false,false,false),
('dky','đăng ký','chat',false,false,false),
('dm','direct message','english',true,false,true),
('dm','địt mẹ','profanity',false,false,false),
('dm','đụ má','profanity',false,false,false),
('dmm','địt mẹ','profanity',false,false,false),
('dmm','địt mẹ mày','profanity',false,false,false),
('dou','đâu','chat',true,true,true),
('dr','đúng rồi','chat',true,true,true),
('dt','dễ thương','chat',false,false,false),
('dt','điện thoại','chat',false,false,false),
('dtcl','đấu trường chân lý','game',false,false,false),
('dth','dễ thương','chat',true,true,true),
('dthuong','dễ thương','chat',true,true,true),
('dthương','dễ thương','chat',true,true,true),
('dthw','dễ thương','chat',true,true,true),
('duma','đụ má','profanity',false,false,false),
('dume','địt mẹ','profanity',false,false,false),
('duoc','được','chat',false,false,false),
('dv','dịch vụ','chat',false,false,false),
('dv','đúng vậy','chat',false,false,false),
('dy','đáng yêu','chat',false,false,false),
('dy','đồng ý','chat',false,false,false),
('dz','đẹp trai','chat',true,true,true),
('dzai','đẹp trai','chat',true,true,true),
('đag','đang','chat',true,true,true),
('đbh','đéo bao giờ','profanity',true,true,false),
('đc','được','chat',true,true,true),
('đcm','địt con mẹ','profanity',true,true,false),
('đcmm','địt con mẹ mày','profanity',true,true,false),
('đei','đây','chat',true,true,true),
('đh','đại học','chat',false,false,false),
('đhieu','đéo hiểu','profanity',false,false,false),
('đhs','đéo hiểu sao','profanity',true,true,false),
('đii','đi','chat',true,true,true),
('đk','đăng ký','chat',false,false,false),
('đk','đúng không','chat',false,false,false),
('đk','được','chat',false,false,false),
('đkm','địt mẹ','profanity',false,false,false),
('đko','đúng không','chat',false,false,false),
('đky','đăng ký','chat',false,false,false),
('đm','địt mẹ','profanity',false,false,false),
('đm','đụ má','profanity',false,false,false),
('đmm','địt mẹ','profanity',false,false,false),
('đmm','địt mẹ mày','profanity',false,false,false),
('đou','đâu','chat',true,true,true),
('đr','đúng rồi','chat',true,true,true),
('đt','điện thoại','chat',false,false,false),
('đuma','đụ má','profanity',false,false,false),
('đv','đúng vậy','chat',false,false,false),
('đx','được','chat',false,false,false),
('đy','đáng yêu','chat',false,false,false),
('đy','đồng ý','chat',false,false,false),
('đz','đẹp trai','chat',true,true,true),
('đzai','đẹp trai','chat',true,true,true),
('egai','em gái','chat',false,false,false),
('éo','đéo','profanity',false,false,false),
('eya','em yêu anh','chat',false,false,false),
('fyi','for your information','english',false,false,false),
('g9','good night','english',false,false,false),
('gf','bạn gái','chat',false,false,false),
('gg','good game','english',false,false,false),
('gi','gì','chat',false,false,false),
('gl','good luck','english',false,false,false),
('gn','good night','english',false,false,false),
('gv','giáo viên','chat',false,false,false),
('hăm','không','chat',false,false,false),
('hb','học bài','chat',false,false,false),
('hd','hợp đồng','chat',false,false,false),
('hd','hướng dẫn','chat',false,false,false),
('hđ','hợp đồng','chat',false,false,false),
('hello','xin chào','chat',false,false,false),
('helo','xin chào','chat',true,true,true),
('hem','không','chat',false,false,false),
('hgl','hẹn gặp lại','chat',false,false,false),
('hk','học kỳ','chat',false,false,false),
('hk','không','chat',false,false,false),
('hkì','học kỳ','chat',true,true,true),
('hn','hôm nay','chat',false,false,false),
('hnay','hôm nay','chat',true,true,true),
('hok','không','chat',true,true,true),
('homnay','hôm nay','chat',false,false,false),
('homqua','hôm qua','chat',false,false,false),
('hong','không','chat',true,true,true),
('hoy','thôi','chat',true,true,true),
('hông','không','chat',true,true,true),
('hp','hạnh phúc','chat',false,false,false),
('hpbd','chúc mừng sinh nhật','chat',true,true,true),
('hphuc','hạnh phúc','chat',true,true,true),
('hphúc','hạnh phúc','chat',true,true,true),
('hq','hôm qua','chat',false,false,false),
('hqua','hôm qua','chat',true,true,true),
('hs','học sinh','chat',false,false,false),
('ib','nhắn tin riêng','chat',false,false,false),
('ibx','nhắn tin riêng','chat',false,false,false),
('idk','I do not know','english',false,false,false),
('imo','in my opinion','english',false,false,false),
('in4','thông tin','chat',true,true,true),
('inbox','nhắn tin riêng','chat',false,false,false),
('info','thông tin','chat',true,true,true),
('iu','yêu','chat',false,false,false),
('j','gì','chat',true,true,true),
('ji','gì','chat',true,true,true),
('jz','gì','chat',false,false,false),
('k','không','chat',true,true,true),
('k biết','không biết','chat',false,false,false),
('k có','không có','chat',false,false,false),
('k hiểu','không hiểu','chat',true,true,true),
('k phải','không phải','chat',false,false,false),
('k sao','không sao','chat',false,false,false),
('k0','không','chat',true,true,true),
('kb','kết bạn','chat',false,false,false),
('kb','không biết','chat',false,false,false),
('kbiet','không biết','chat',false,false,false),
('kbt','không biết','chat',true,true,true),
('kco','không có','chat',false,false,false),
('kh','khách hàng','chat',false,false,false),
('kh','không','chat',false,false,false),
('khbt','không biết','chat',false,false,false),
('khg','không','chat',false,false,false),
('khieu','không hiểu','chat',true,true,true),
('khong','không','chat',false,false,false),
('khôg','không','chat',false,false,false),
('khôngg','không','chat',false,false,false),
('khum','không','chat',true,true,true),
('klq','không liên quan','chat',true,true,true),
('ko','không','chat',true,true,true),
('kô','không','chat',true,true,true),
('kph','không phải','chat',false,false,false),
('kphai','không phải','chat',false,false,false),
('ks','không sao','chat',false,false,false),
('ksao','không sao','chat',true,true,true),
('kt','kiểm tra','chat',false,false,false),
('ktra','kiểm tra','chat',true,true,true),
('lgi','làm gì','chat',false,false,false),
('lmgi','làm gì','chat',false,false,false),
('lmht','liên minh huyền thoại','game',false,false,false),
('lmj','làm gì','chat',false,false,false),
('lmsao','làm sao','chat',false,false,false),
('lnao','lúc nào','chat',false,false,false),
('lol','laughing out loud','english',false,false,false),
('lol','League of Legends','game',false,false,false),
('lol','lồn','profanity',true,true,false),
('loz','lồn','profanity',false,false,false),
('lozz','lồn','profanity',false,false,false),
('lq','liên quan','chat',false,false,false),
('lq','liên quân','game',false,false,false),
('lqm','liên quân mobile','game',false,false,false),
('lquan','liên quan','chat',true,true,true),
('lsao','làm sao','chat',false,false,false),
('lun','liền','chat',false,false,false),
('lun','luôn','chat',false,false,false),
('luon','luôn','chat',false,false,false),
('lv','làm việc','chat',false,false,false),
('lz','lồn','profanity',false,false,false),
('m','mày','chat',false,false,false),
('mik','mình','chat',true,true,true),
('mjh','mình','chat',true,true,true),
('mk','mật khẩu','chat',false,false,false),
('mk','mình','chat',false,false,false),
('mn','mọi người','chat',false,false,false),
('mng','mọi người','chat',true,true,true),
('mngười','mọi người','chat',true,true,true),
('mọi ng','mọi người','chat',false,false,false),
('ms','mới','chat',true,true,true),
('nc','nói chung','chat',false,false,false),
('nc','nói chuyện','chat',false,false,false),
('nch','nói chuyện','chat',true,true,true),
('nchung','nói chung','chat',true,true,true),
('ng','người','chat',false,false,false),
('ngấy','người ấy','chat',false,false,false),
('nghqua','ngày hôm qua','chat',false,false,false),
('ngiu','người yêu','chat',false,false,false),
('ngmai','ngày mai','chat',false,false,false),
('ngta','người ta','chat',true,true,true),
('ngừi','người','chat',false,false,false),
('ngyeu','người yêu','chat',true,true,true),
('nhantin','nhắn tin','chat',false,false,false),
('nhg','nhưng','chat',true,true,true),
('nhiu','nhiều','chat',true,true,true),
('nhìu','nhiều','chat',true,true,true),
('nhưg','nhưng','chat',true,true,true),
('nmai','ngày mai','chat',false,false,false),
('nt','nhắn tin','chat',false,false,false),
('nt','nói thật','chat',false,false,false),
('nta','người ta','chat',true,true,true),
('nthật','nói thật','chat',false,false,false),
('nthe','như thế','chat',true,true,true),
('ntin','nhắn tin','chat',false,false,false),
('ntn','như thế nào','chat',true,true,true),
('ntnao','như thế nào','chat',true,true,true),
('nữaa','nữa','chat',true,true,true),
('nv','nhân viên','chat',false,false,false),
('nx','nữa','chat',false,false,false),
('ny','người yêu','chat',true,true,true),
('nyc','người yêu cũ','chat',true,true,true),
('òi','rồi','chat',true,true,true),
('ok','đồng ý','chat',false,false,false),
('oke','đồng ý','chat',false,false,false),
('okela','đồng ý','chat',false,false,false),
('oki','đồng ý','chat',false,false,false),
('okie','đồng ý','chat',false,false,false),
('omg','oh my god','english',false,false,false),
('oy','rồi','chat',true,true,true),
('òy','rồi','chat',true,true,true),
('pm','private message','english',false,false,false),
('pp','tạm biệt','chat',false,false,false),
('pv','phỏng vấn','chat',false,false,false),
('qá','quá','chat',true,true,true),
('qt','quan tâm','chat',false,false,false),
('qtam','quan tâm','chat',true,true,true),
('qtâm','quan tâm','chat',true,true,true),
('qtr','quan trọng','chat',true,true,true),
('qtrong','quan trọng','chat',true,true,true),
('r','rồi','chat',true,true,true),
('rấtt','rất','chat',false,false,false),
('rep','trả lời','chat',false,false,false),
('ròi','rồi','chat',false,false,false),
('roii','rồi','chat',false,false,false),
('ròii','rồi','chat',false,false,false),
('rùi','rồi','chat',true,true,true),
('sauu','sau','chat',false,false,false),
('sdt','số điện thoại','chat',true,true,true),
('sđt','số điện thoại','chat',true,true,true),
('sml','sấp mặt lồn','profanity',true,true,false),
('sml','sấp mặt luôn','euphemism',true,false,true),
('sorry','xin lỗi','chat',true,true,true),
('sp','sản phẩm','chat',false,false,false),
('sr','xin lỗi','chat',true,true,true),
('sry','xin lỗi','chat',true,true,true),
('stk','số tài khoản','chat',true,true,true),
('sv','sinh viên','chat',false,false,false),
('t','tao','chat',false,false,false),
('t','tôi','chat',false,false,false),
('t','tớ','chat',false,false,false),
('tb','thông báo','chat',false,false,false),
('tbh','to be honest','english',false,false,false),
('tdn','thế đéo nào','profanity',true,true,false),
('tđn','thế đéo nào','profanity',true,true,false),
('tg','thế giới','chat',false,false,false),
('tg','thời gian','chat',false,false,false),
('tgian','thời gian','chat',false,false,false),
('thank','cảm ơn','chat',false,false,false),
('thanks','cảm ơn','chat',false,false,false),
('thậtt','thật','chat',false,false,false),
('thcs','trung học cơ sở','chat',false,false,false),
('thgian','thời gian','chat',false,false,false),
('thich','thích','chat',false,false,false),
('thíck','thích','chat',true,true,true),
('thik','thích','chat',false,false,false),
('thjk','thích','chat',false,false,false),
('thoi','thôi','chat',false,false,false),
('thoy','thôi','chat',true,true,true),
('thpt','trung học phổ thông','chat',false,false,false),
('thra','thật ra','chat',false,false,false),
('ths','thật sự','chat',false,false,false),
('thsu','thật sự','chat',false,false,false),
('tht','thật','chat',false,false,false),
('thui','thôi','chat',true,true,true),
('thx','cảm ơn','chat',true,true,true),
('tk','tài khoản','chat',false,false,false),
('tks','cảm ơn','chat',true,true,true),
('tl','trả lời','chat',false,false,false),
('tn','thế nào','chat',false,false,false),
('tn','tin nhắn','chat',false,false,false),
('tn','tuy nhiên','chat',false,false,false),
('tnào','thế nào','chat',true,true,true),
('trc','trước','chat',false,false,false),
('trhoc','trường học','chat',true,true,true),
('trloi','trả lời','chat',false,false,false),
('trướcc','trước','chat',false,false,false),
('ts','tại sao','chat',false,false,false),
('tsao','tại sao','chat',true,true,true),
('tsau','tuần sau','chat',false,false,false),
('tt','trung tâm','chat',false,false,false),
('tt','từ từ','chat',false,false,false),
('ttrc','tuần trước','chat',false,false,false),
('tv','tại vì','chat',false,false,false),
('tvi','tại vì','chat',true,true,true),
('v','vậy','chat',false,false,false),
('vay','vậy','chat',false,false,false),
('vc','vãi chưởng','euphemism',false,false,false),
('vc','vợ chồng','chat',false,false,false),
('vcc','vãi cả cặc','profanity',false,false,false),
('vcd','vãi cả đái','profanity',false,false,false),
('vcđ','vãi cả đái','profanity',false,false,false),
('vch','vãi chưởng','euphemism',false,false,false),
('vchg','vãi chưởng','euphemism',false,false,false),
('vchưởng','vãi chưởng','euphemism',false,false,false),
('vcl','vãi cả lồn','profanity',true,true,false),
('vcl','vãi cả lúa','euphemism',true,false,true),
('vd','vãi đái','profanity',true,true,false),
('vd','ví dụ','chat',true,false,true),
('vde','vấn đề','chat',true,true,true),
('vdu','ví dụ','chat',true,true,true),
('vđ','vãi đái','profanity',true,true,false),
('vđ','vấn đề','chat',true,false,true),
('vđề','vấn đề','chat',true,true,true),
('vk','vợ','chat',false,false,false),
('vkl','vãi cả lồn','profanity',false,false,false),
('vkll','vãi cả lồn','profanity',false,false,false),
('vl','vãi lồn','profanity',false,false,false),
('vler','vãi lồn','profanity',false,false,false),
('vll','vãi lồn','profanity',false,false,false),
('vs','với','chat',true,true,true),
('vv','vì vậy','chat',false,false,false),
('vv','vui vẻ','chat',false,false,false),
('wa','quá','chat',true,true,true),
('wá','quá','chat',true,true,true),
('wtf','what the fuck','english',false,false,false),
('xg','xong','chat',false,false,false),
('xg','xuống','chat',false,false,false),
('xl','xạo lồn','profanity',true,true,false),
('xl','xin lỗi','chat',true,false,true),
('xlone','xạo lồn','profanity',false,false,false),
('xog','xong','chat',false,false,false),
('z','vậy','chat',true,true,true),
('zậy','vậy','chat',true,true,true),
('ze','về','chat',true,true,true),
('zề','về','chat',true,true,true),
('zi','vậy','chat',false,false,false),
('zo','vào','chat',true,true,true),
('zô','vào','chat',true,true,true)
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
