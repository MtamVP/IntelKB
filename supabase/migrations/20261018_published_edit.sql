-- Owner-only, revision-checked edits of already published dictionary entries.
begin;
create or replace function public.intelkb_save_published(p_receipt uuid,p_id uuid,p_revision integer,p_entry jsonb,p_note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare value public.intelkb_dictionary;prior public.intelkb_review_actions;key text;payload jsonb;before_state jsonb;after_state jsonb;report jsonb;action_id uuid:=gen_random_uuid();
 v_meaning text;v_category text;v_auto boolean;
begin
 if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501';end if;
 if p_receipt is null or p_id is null or p_revision is null or p_entry is null or jsonb_typeof(p_entry)<>'object' then raise exception 'Invalid published edit';end if;
 payload:=jsonb_build_object('id',p_id,'revision',p_revision,'entry',p_entry,'note',p_note);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_receipt::text,31));
 select * into prior from public.intelkb_review_actions where receipt=p_receipt;
 if found then
  if prior.actor<>auth.uid() or prior.payload<>payload or prior.undone_at is not null then raise exception 'Receipt already used';end if;
  return prior.report;
 end if;
 select public.intelkb_alias_key(trigger) into key from public.intelkb_dictionary where id=p_id;
 if key is null then raise exception 'Published entry not found';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(key,71));
 perform 1 from public.intelkb_dictionary where public.intelkb_alias_key(trigger)=key order by id for update;
 select * into value from public.intelkb_dictionary where id=p_id;
 if not found or value.status<>'approved' or value.revision<>p_revision then raise exception 'Entry changed; reload before saving';end if;
 if public.intelkb_alias_key(p_entry->>'trigger')<>key or not(p_entry ? 'trigger') then raise exception 'Cannot rename published entry in this editor';end if;
 v_meaning:=btrim(regexp_replace(normalize(p_entry->>'expansion',NFC),'\s+',' ','g'));
 v_category:=p_entry->>'category';
 if v_meaning is null or char_length(v_meaning) not between 1 and 240 or lower(v_meaning)=key or v_category is null or v_category not in ('chat','profanity','euphemism','english','game')
 or jsonb_typeof(p_entry->'auto_replace') is distinct from 'boolean' or char_length(coalesce(p_note,''))>1000 then raise exception 'Invalid word or meaning';end if;
 v_auto:=(p_entry->>'auto_replace')::boolean;
 if exists(select 1 from public.intelkb_dictionary d where d.id<>p_id and d.status='approved' and public.intelkb_pair_key(d.trigger,d.expansion)=public.intelkb_pair_key(value.trigger,v_meaning)) then raise exception 'Word and meaning already published' using errcode='23505';end if;
 before_state:=public.intelkb_review_snapshot(array[key],'{}'::uuid[]);
 if (value.expansion,value.category,value.auto_replace) is distinct from (v_meaning,v_category,v_auto) then
  update public.intelkb_dictionary set expansion=v_meaning,category=v_category,auto_replace=v_auto,
   auto_direct=auto_direct and v_auto,auto_gentle=auto_gentle and v_auto and v_category<>'profanity',
   revision=revision+1,updated_at=now(),reviewed_at=now(),reviewed_by=auth.uid() where id=p_id;
  -- A category change must not leave a mode pointing at an incompatible meaning.
  update public.intelkb_dictionary d set auto_direct=false,revision=d.revision+1,updated_at=now()
   where d.status='approved' and public.intelkb_alias_key(d.trigger)=key and d.auto_direct and d.category<>'profanity'
   and exists(select 1 from public.intelkb_dictionary p where p.status='approved' and public.intelkb_alias_key(p.trigger)=key and p.category='profanity');
 end if;
 after_state:=public.intelkb_review_snapshot(array[key],'{}'::uuid[]);
 report:=jsonb_build_object('action_id',action_id,'undo_available',before_state<>after_state,'ok',1,'failed',0,'rows',jsonb_build_array(jsonb_build_object('id',p_id,'ok',true)));
 insert into public.intelkb_review_actions(id,receipt,actor,aliases,proposal_ids,payload,before_state,after_state,report)
 values(action_id,p_receipt,auth.uid(),array[key],'{}',payload,before_state,after_state,report);
 return report;
end;$$;
revoke all on function public.intelkb_save_published(uuid,uuid,integer,jsonb,text) from public;
grant execute on function public.intelkb_save_published(uuid,uuid,integer,jsonb,text) to authenticated;
notify pgrst,'reload schema';
commit;
