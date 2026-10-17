-- Paste this entire file into the project's Supabase SQL Editor and Run.
-- Browser clients use Supabase Auth + their publishable key; no secret key needed.
begin;
create table if not exists public.intelkb_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  trigger text not null check (char_length(trigger) between 1 and 48),
  expansion text not null check (char_length(expansion) between 1 and 240),
  category text not null default 'chat' check (category in ('chat','profanity','euphemism','english','game')),
  auto_replace boolean not null default false,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists intelkb_entries_user_id_idx on public.intelkb_entries(user_id);
alter table public.intelkb_entries enable row level security;
revoke all on public.intelkb_entries from anon, authenticated;
grant select, insert, update on public.intelkb_entries to authenticated;
drop policy if exists intelkb_read_own on public.intelkb_entries;
create policy intelkb_read_own on public.intelkb_entries for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists intelkb_insert_own on public.intelkb_entries;
create policy intelkb_insert_own on public.intelkb_entries for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists intelkb_update_own on public.intelkb_entries;
create policy intelkb_update_own on public.intelkb_entries for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
-- Deletes are recoverable tombstones (deleted_at); no browser hard-delete grant.
notify pgrst, 'reload schema';
commit;
