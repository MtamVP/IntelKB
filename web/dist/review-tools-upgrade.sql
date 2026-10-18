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
