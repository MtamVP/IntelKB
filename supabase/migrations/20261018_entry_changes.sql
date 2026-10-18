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
