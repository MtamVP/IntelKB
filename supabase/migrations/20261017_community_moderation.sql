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
