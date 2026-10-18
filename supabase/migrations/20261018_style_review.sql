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
