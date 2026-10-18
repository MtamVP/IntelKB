-- IntelKB P0/P1: Data management + bulk moderation
-- Run after existing migrations. Safe to re-run (uses IF NOT EXISTS).
begin;

-- ── P0-C: Mở rộng bảng intelkb_dictionary ────────────────────────────────
alter table public.intelkb_dictionary
  add column if not exists example       text not null default '' check(char_length(example)       <= 500),
  add column if not exists source_ref    text not null default '' check(char_length(source_ref)    <= 500),
  add column if not exists internal_note text not null default '' check(char_length(internal_note) <= 1000),
  add column if not exists trashed_at    timestamptz,
  add column if not exists trashed_by    uuid references auth.users(id);

-- Cập nhật ràng buộc source để cho phép giá trị 'import'
alter table public.intelkb_dictionary drop constraint if exists intelkb_dictionary_source_check;
alter table public.intelkb_dictionary
  add constraint intelkb_dictionary_source_check
  check(source in ('bootstrap','community','import'));

-- Index tìm kiếm nhanh hơn
create index if not exists intelkb_dict_trigger_idx  on public.intelkb_dictionary(lower(trigger));
create index if not exists intelkb_dict_status_idx   on public.intelkb_dictionary(status, trashed_at);
create index if not exists intelkb_dict_source_idx   on public.intelkb_dictionary(source);

-- ── P0-C: Bảng lịch sử ───────────────────────────────────────────────────
create table if not exists public.intelkb_history (
  id         uuid primary key default gen_random_uuid(),
  entry_id   uuid not null references public.intelkb_dictionary(id) on delete cascade,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  action     text not null check(action in ('create','edit','approve','reject','trash','restore','import','bulk_review')),
  reason     text not null default '',
  before_data jsonb,
  after_data  jsonb not null
);
create index if not exists intelkb_history_entry_idx on public.intelkb_history(entry_id, changed_at desc);
alter table public.intelkb_history enable row level security;
revoke all on public.intelkb_history from anon, authenticated;
grant select on public.intelkb_history to authenticated;
drop policy if exists intelkb_history_admin_read on public.intelkb_history;
create policy intelkb_history_admin_read on public.intelkb_history
  for select to authenticated using(public.intelkb_is_admin());

-- Cập nhật RLS để admin đọc được mọi trạng thái
drop policy if exists intelkb_catalogue_read on public.intelkb_dictionary;
create policy intelkb_catalogue_read on public.intelkb_dictionary
  for select to anon, authenticated
  using(status = 'approved' or public.intelkb_is_admin());

-- ── P0-C: RPC admin_upsert ────────────────────────────────────────────────
create or replace function public.intelkb_admin_upsert(
  p_id            uuid    default null,
  p_trigger       text    default null,
  p_expansion     text    default null,
  p_category      text    default null,
  p_auto_replace  boolean default false,
  p_status        text    default 'draft',
  p_source        text    default 'import',
  p_example       text    default '',
  p_source_ref    text    default '',
  p_internal_note text    default '',
  p_reason        text    default ''
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_old      public.intelkb_dictionary;
  v_trigger  text := lower(regexp_replace(btrim(normalize(p_trigger,NFC)),'\s+',' ','g'));
  v_expansion text := regexp_replace(btrim(normalize(p_expansion,NFC)),'\s+',' ','g');
  v_is_new   boolean;
  v_id       uuid;
begin
  if not public.intelkb_is_admin() then
    raise exception 'Administrator required' using errcode='42501';
  end if;
  if p_status not in ('draft','approved','rejected') then raise exception 'Invalid status'; end if;
  if p_source not in ('bootstrap','community','import') then raise exception 'Invalid source'; end if;
  if v_trigger is null or char_length(v_trigger) not between 1 and 48 then raise exception 'Từ viết tắt cần 1–48 ký tự'; end if;
  if v_expansion is null or char_length(v_expansion) not between 1 and 240 then raise exception 'Nghĩa cần 1–240 ký tự'; end if;
  if p_category not in ('chat','profanity','euphemism','english','game') then raise exception 'Nhóm từ không hợp lệ'; end if;
  if lower(v_trigger) = lower(v_expansion) then raise exception 'Viết tắt và nghĩa phải khác nhau'; end if;

  if p_id is not null then
    -- UPDATE
    select * into v_old from public.intelkb_dictionary where id=p_id for update;
    if not found then raise exception 'Không tìm thấy mục'; end if;
    if v_old.trashed_at is not null then raise exception 'Khôi phục mục trước khi sửa'; end if;
    update public.intelkb_dictionary set
      trigger=v_trigger, expansion=v_expansion, category=p_category,
      auto_replace=p_auto_replace, status=p_status,
      example=coalesce(p_example,''), source_ref=coalesce(p_source_ref,''),
      internal_note=coalesce(p_internal_note,''),
      reviewed_by=case when p_status<>v_old.status and p_status in ('approved','rejected') then auth.uid() else reviewed_by end,
      reviewed_at=case when p_status<>v_old.status and p_status in ('approved','rejected') then now() else reviewed_at end,
      updated_at=now(), revision=revision+1
    where id=p_id returning id into v_id;
    v_is_new := false;
  else
    -- INSERT
    insert into public.intelkb_dictionary
      (trigger,expansion,category,auto_replace,status,source,example,source_ref,internal_note,reviewed_by,reviewed_at)
    values(v_trigger,v_expansion,p_category,p_auto_replace,p_status,p_source,
      coalesce(p_example,''),coalesce(p_source_ref,''),coalesce(p_internal_note,''),
      case when p_status in ('approved','rejected') then auth.uid() else null end,
      case when p_status in ('approved','rejected') then now() else null end)
    returning id into v_id;
    v_is_new := true;
  end if;

  insert into public.intelkb_history(entry_id,changed_by,action,reason,before_data,after_data)
  select v_id, auth.uid(),
    case when v_is_new then 'create'
         when p_status='approved' and (v_old.status is null or v_old.status<>'approved') then 'approve'
         when p_status='rejected' and (v_old.status is null or v_old.status<>'rejected') then 'reject'
         else 'edit' end,
    coalesce(p_reason,''),
    case when v_is_new then null else to_jsonb(v_old) end,
    (select to_jsonb(d) from public.intelkb_dictionary d where id=v_id);

  return jsonb_build_object(
    'id',v_id,'is_new',v_is_new,
    'revision',(select revision from public.intelkb_dictionary where id=v_id)
  );
end; $$;
revoke all on function public.intelkb_admin_upsert from public;
grant execute on function public.intelkb_admin_upsert to authenticated;

-- ── P0-C: RPC admin_trash ─────────────────────────────────────────────────
create or replace function public.intelkb_admin_trash(p_id uuid, p_reason text default '')
returns void language plpgsql security definer set search_path='' as $$
declare v_old public.intelkb_dictionary;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  select * into v_old from public.intelkb_dictionary where id=p_id for update;
  if not found then raise exception 'Không tìm thấy mục'; end if;
  if v_old.trashed_at is not null then raise exception 'Mục đã trong thùng rác'; end if;
  update public.intelkb_dictionary
    set trashed_at=now(), trashed_by=auth.uid(), updated_at=now()
  where id=p_id;
  insert into public.intelkb_history(entry_id,changed_by,action,reason,before_data,after_data)
  select p_id,auth.uid(),'trash',coalesce(p_reason,''),to_jsonb(v_old),
    (select to_jsonb(d) from public.intelkb_dictionary d where id=p_id);
end; $$;
revoke all on function public.intelkb_admin_trash from public;
grant execute on function public.intelkb_admin_trash to authenticated;

-- ── P0-C: RPC admin_restore ───────────────────────────────────────────────
create or replace function public.intelkb_admin_restore(p_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_old public.intelkb_dictionary;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  select * into v_old from public.intelkb_dictionary where id=p_id for update;
  if not found then raise exception 'Không tìm thấy mục'; end if;
  if v_old.trashed_at is null then raise exception 'Mục chưa bị xóa'; end if;
  update public.intelkb_dictionary
    set trashed_at=null, trashed_by=null, updated_at=now(), revision=revision+1
  where id=p_id;
  insert into public.intelkb_history(entry_id,changed_by,action,reason,before_data,after_data)
  select p_id,auth.uid(),'restore','',to_jsonb(v_old),
    (select to_jsonb(d) from public.intelkb_dictionary d where id=p_id);
end; $$;
revoke all on function public.intelkb_admin_restore from public;
grant execute on function public.intelkb_admin_restore to authenticated;

-- ── P0-C: RPC bulk_import ─────────────────────────────────────────────────
create or replace function public.intelkb_bulk_import(
  p_rows        jsonb,
  p_source_name text default ''
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_row       jsonb;
  v_trigger   text; v_expansion text; v_id uuid;
  v_results   jsonb := '[]'::jsonb;
  v_result    jsonb;
  v_imported  int := 0; v_skipped int := 0; v_errors int := 0;
  v_idx       int := 0;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  if jsonb_array_length(p_rows) > 10000 then raise exception 'Tối đa 10.000 dòng mỗi lần gọi'; end if;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx+1;
    begin
      v_trigger   := lower(regexp_replace(btrim(normalize(v_row->>'trigger',NFC)),'\s+',' ','g'));
      v_expansion := regexp_replace(btrim(normalize(v_row->>'expansion',NFC)),'\s+',' ','g');
      if v_trigger is null or char_length(v_trigger) not between 1 and 48
        or v_expansion is null or char_length(v_expansion) not between 1 and 240
        or lower(v_trigger)=lower(v_expansion)
        or (v_row->>'category') not in ('chat','profanity','euphemism','english','game')
      then raise exception 'Dữ liệu dòng không hợp lệ'; end if;

      if exists(
        select 1 from public.intelkb_dictionary
        where lower(trigger)=lower(v_trigger) and lower(expansion)=lower(v_expansion)
          and status in ('approved','draft') and trashed_at is null
      ) then
        v_skipped := v_skipped+1;
        v_result := jsonb_build_object('index',v_idx,'status','skipped','trigger',v_trigger,'expansion',v_expansion,'reason','Đã tồn tại');
      else
        insert into public.intelkb_dictionary
          (trigger,expansion,category,auto_replace,status,source,example,source_ref)
        values(v_trigger,v_expansion,v_row->>'category',
          coalesce((v_row->>'auto_replace')::boolean,false),
          'draft','import',
          coalesce(v_row->>'example',''),
          coalesce(p_source_name,''))
        returning id into v_id;
        insert into public.intelkb_history(entry_id,changed_by,action,reason,before_data,after_data)
        select v_id,auth.uid(),'import',coalesce(p_source_name,''),null,
          (select to_jsonb(d) from public.intelkb_dictionary d where id=v_id);
        v_imported := v_imported+1;
        v_result := jsonb_build_object('index',v_idx,'status','ok','id',v_id,'trigger',v_trigger,'expansion',v_expansion);
      end if;
    exception when others then
      v_errors := v_errors+1;
      v_result := jsonb_build_object('index',v_idx,'status','error',
        'trigger',v_row->>'trigger','expansion',v_row->>'expansion','reason',sqlerrm);
    end;
    v_results := v_results || v_result;
  end loop;
  return jsonb_build_object('imported',v_imported,'skipped',v_skipped,'errors',v_errors,'rows',v_results);
end; $$;
revoke all on function public.intelkb_bulk_import(jsonb,text) from public;
grant execute on function public.intelkb_bulk_import(jsonb,text) to authenticated;

-- ── P0-C: RPC entry_history ───────────────────────────────────────────────
create or replace function public.intelkb_entry_history(p_id uuid)
returns setof public.intelkb_history language sql stable security definer set search_path='' as $$
  select * from public.intelkb_history where entry_id=p_id order by changed_at desc limit 50;
$$;
revoke all on function public.intelkb_entry_history(uuid) from public;
grant execute on function public.intelkb_entry_history(uuid) to authenticated;

-- ── P0-C: RPC stats ───────────────────────────────────────────────────────
create or replace function public.intelkb_admin_stats()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'dict_draft',    count(*) filter(where status='draft'    and trashed_at is null),
    'dict_approved', count(*) filter(where status='approved' and trashed_at is null),
    'dict_rejected', count(*) filter(where status='rejected' and trashed_at is null),
    'dict_trashed',  count(*) filter(where trashed_at is not null),
    'prop_pending',  (select count(*) from public.intelkb_proposals where status='pending'),
    'prop_accepted', (select count(*) from public.intelkb_proposals where status='accepted'),
    'prop_rejected', (select count(*) from public.intelkb_proposals where status='rejected')
  )
  from public.intelkb_dictionary;
$$;
revoke all on function public.intelkb_admin_stats() from public;
grant execute on function public.intelkb_admin_stats() to authenticated;

-- ── P1-C: RPC bulk_review ─────────────────────────────────────────────────
create or replace function public.intelkb_bulk_review(
  p_items jsonb  -- [{id, kind:'seed'|'proposal', decision, note?, revision?, override?}]
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_item    jsonb; v_id uuid;
  v_results jsonb := '[]'::jsonb;
  v_result  jsonb;
  v_ok int := 0; v_fail int := 0;
begin
  if not public.intelkb_is_admin() then raise exception 'Administrator required' using errcode='42501'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_id := (v_item->>'id')::uuid;
    begin
      if v_item->>'kind'='seed' then
        perform public.intelkb_review_seed(
          v_id, v_item->>'decision',
          (v_item->>'revision')::integer,
          v_item->'override'
        );
      else
        perform public.intelkb_review_proposal(
          v_id, v_item->>'decision',
          coalesce(v_item->>'note',''),
          v_item->'override'
        );
      end if;
      v_ok := v_ok+1;
      v_result := jsonb_build_object('id',v_id,'status','ok','decision',v_item->>'decision');
    exception when others then
      v_fail := v_fail+1;
      v_result := jsonb_build_object('id',v_id,'status','error','reason',sqlerrm);
    end;
    v_results := v_results||v_result;
  end loop;
  return jsonb_build_object('ok',v_ok,'fail',v_fail,'rows',v_results);
end; $$;
revoke all on function public.intelkb_bulk_review(jsonb) from public;
grant execute on function public.intelkb_bulk_review(jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
