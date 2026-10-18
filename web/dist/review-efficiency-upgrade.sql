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
