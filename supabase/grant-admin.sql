-- Run manually in SQL Editor AFTER creating your own account in Authentication → Users.
-- Replace EMAIL_QUAN_TRI below with that account's email. Do not put a password here.
do $$
declare v_email text := 'vophucminhtam@gmail.com'; v_user uuid;
begin
  select id into v_user from auth.users where lower(email)=lower(v_email);
  if v_user is null then raise exception 'Create the Auth user first and replace EMAIL_QUAN_TRI'; end if;
  insert into public.intelkb_admins(user_id) values(v_user) on conflict(user_id) do nothing;
end; $$;
