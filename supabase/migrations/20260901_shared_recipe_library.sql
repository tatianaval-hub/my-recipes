-- Общий доступ к библиотеке рецептов по персональному коду.
-- Запустите этот скрипт в Supabase Dashboard → SQL Editor → New query.
-- Скрипт безопасно повторно выполнять: все объекты создаются идемпотентно.

-- 1. Профили пользователей с персональным кодом доступа ---------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  share_code text not null unique,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Пользователь видит только свой профиль.
drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile"
on public.profiles
for select
to authenticated
using (id = auth.uid());

-- 2. Таблица выданных доступов ----------------------------------------------

create table if not exists public.recipe_library_access (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  viewer_id uuid not null references auth.users(id) on delete cascade,
  permission text not null default 'viewer' check (permission in ('viewer')),
  created_at timestamptz not null default now(),
  constraint recipe_library_access_unique unique (owner_id, viewer_id),
  constraint recipe_library_access_not_self check (owner_id <> viewer_id)
);

create index if not exists recipe_library_access_viewer_idx
  on public.recipe_library_access (viewer_id);

alter table public.recipe_library_access enable row level security;

-- Владелец видит, кому он выдал доступ. Гость видит, кто ему выдал доступ.
drop policy if exists "Participants can read access rows" on public.recipe_library_access;
create policy "Participants can read access rows"
on public.recipe_library_access
for select
to authenticated
using (owner_id = auth.uid() or viewer_id = auth.uid());

-- Владелец может отозвать выданный им доступ.
drop policy if exists "Owners can revoke access" on public.recipe_library_access;
create policy "Owners can revoke access"
on public.recipe_library_access
for delete
to authenticated
using (owner_id = auth.uid());

-- Запись доступа создаётся только через защищённую функцию ниже,
-- поэтому политика INSERT для клиента намеренно не создаётся.

-- 3. Доступ на чтение чужих рецептов -----------------------------------------

drop policy if exists "Viewers can read shared recipes" on public.recipes;
create policy "Viewers can read shared recipes"
on public.recipes
for select
to authenticated
using (
  exists (
    select 1
    from public.recipe_library_access a
    where a.owner_id = public.recipes.user_id
      and a.viewer_id = auth.uid()
  )
);

-- Права INSERT / UPDATE / DELETE остаются только у владельца:
-- существующие политики не изменяются, новые не добавляются.

-- 4. Персональный код пользователя -------------------------------------------

create or replace function public.get_my_share_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then
    raise exception 'Требуется вход в аккаунт';
  end if;

  select share_code into v_code from public.profiles where id = v_uid;
  if v_code is not null then
    return v_code;
  end if;

  loop
    v_code := upper(encode(gen_random_bytes(5), 'hex'));
    begin
      insert into public.profiles (id, share_code) values (v_uid, v_code);
      return v_code;
    exception
      when unique_violation then
        select share_code into v_code from public.profiles where id = v_uid;
        if v_code is not null then
          return v_code;
        end if;
    end;
  end loop;
end;
$$;

revoke all on function public.get_my_share_code() from public, anon;
grant execute on function public.get_my_share_code() to authenticated;

-- 5. Выдача доступа по коду ---------------------------------------------------

create or replace function public.grant_library_access_by_code(p_code text)
returns table (viewer_id uuid, share_code text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner  uuid := auth.uid();
  v_viewer uuid;
  v_code   text := upper(btrim(coalesce(p_code, '')));
begin
  if v_owner is null then
    raise exception 'Требуется вход в аккаунт';
  end if;
  if v_code = '' then
    raise exception 'Введите код пользователя';
  end if;

  select id into v_viewer from public.profiles where share_code = v_code;
  if v_viewer is null then
    raise exception 'Пользователь с таким кодом не найден';
  end if;
  if v_viewer = v_owner then
    raise exception 'Это ваш собственный код';
  end if;

  insert into public.recipe_library_access (owner_id, viewer_id, permission)
  values (v_owner, v_viewer, 'viewer')
  on conflict (owner_id, viewer_id) do nothing;

  return query
    select a.viewer_id, v_code, a.created_at
    from public.recipe_library_access a
    where a.owner_id = v_owner and a.viewer_id = v_viewer;
end;
$$;

revoke all on function public.grant_library_access_by_code(text) from public, anon;
grant execute on function public.grant_library_access_by_code(text) to authenticated;

-- 6. Список выданных доступов -------------------------------------------------

create or replace function public.list_library_access()
returns table (viewer_id uuid, share_code text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select a.viewer_id, p.share_code, a.created_at
  from public.recipe_library_access a
  join public.profiles p on p.id = a.viewer_id
  where a.owner_id = auth.uid()
  order by a.created_at desc;
$$;

revoke all on function public.list_library_access() from public, anon;
grant execute on function public.list_library_access() to authenticated;

-- 7. Список библиотек, доступных мне ------------------------------------------

create or replace function public.list_shared_with_me()
returns table (owner_id uuid, share_code text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select a.owner_id, p.share_code, a.created_at
  from public.recipe_library_access a
  join public.profiles p on p.id = a.owner_id
  where a.viewer_id = auth.uid()
  order by a.created_at desc;
$$;

revoke all on function public.list_shared_with_me() from public, anon;
grant execute on function public.list_shared_with_me() to authenticated;

-- 8. Отзыв доступа -------------------------------------------------------------

create or replace function public.revoke_library_access(p_viewer_id uuid)
returns void
language sql
security invoker
set search_path = public
as $$
  delete from public.recipe_library_access
  where owner_id = auth.uid() and viewer_id = p_viewer_id;
$$;

revoke all on function public.revoke_library_access(uuid) from public, anon;
grant execute on function public.revoke_library_access(uuid) to authenticated;
