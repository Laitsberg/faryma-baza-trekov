-- ============================================================
-- База треков Faryma: таблицы для входа через Twitch.
--
-- Вставляется целиком в Supabase → SQL Editor → Run. Повторный
-- запуск ничего не ломает: всё создаётся через «if not exists» /
-- «or replace», политики пересоздаются.
--
-- Устройство:
--   profiles — кто вошёл. Ник и аватар пишет сервер из данных
--              Twitch (триггер на auth.users), сам зритель может
--              менять только цвет человечка и пару слов о себе:
--              иначе на главной можно было бы назваться кем угодно.
--   ratings  — свои оценки. Видит и меняет только владелец.
--   favs     — сердечки. Так же.
--   online   — кто сейчас на сайте: вошедший раз в минуту отмечается,
--              время ставит сервер. Читать могут все — это и есть
--              человечки на главной (через представление online_now).
--
-- «Automatically expose new tables» при создании проекта выключен,
-- поэтому доступ к каждой таблице ниже выдаётся явно (grant).
-- ============================================================

-- ---------- профили ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  twitch_id   text,
  login       text,
  name        text,
  avatar_url  text,
  color       text check (color ~ '^#[0-9A-Fa-f]{6}$'),
  bio         text check (char_length(bio) <= 90),
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to anon, authenticated using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (color, bio) on public.profiles to authenticated;

-- Twitch отдаёт: name — логин, nickname — отображаемое имя,
-- avatar_url / picture — аватар, provider_id — id на Twitch.
create or replace function public.profile_from_auth()
returns trigger language plpgsql security definer set search_path = '' as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, twitch_id, login, name, avatar_url)
  values (new.id,
          m->>'provider_id',
          m->>'name',
          left(coalesce(m->>'nickname', m->>'name'), 60),
          coalesce(m->>'avatar_url', m->>'picture'))
  on conflict (id) do update
    set twitch_id  = excluded.twitch_id,
        login      = excluded.login,
        name       = excluded.name,
        avatar_url = excluded.avatar_url;
  return new;
end $$;
revoke execute on function public.profile_from_auth() from public, anon, authenticated;

drop trigger if exists on_auth_user_saved on auth.users;
create trigger on_auth_user_saved
  after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.profile_from_auth();

-- Кто вошёл до того, как появилась эта таблица.
insert into public.profiles (id, twitch_id, login, name, avatar_url)
select u.id,
       u.raw_user_meta_data->>'provider_id',
       u.raw_user_meta_data->>'name',
       left(coalesce(u.raw_user_meta_data->>'nickname', u.raw_user_meta_data->>'name'), 60),
       coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture')
from auth.users u
on conflict (id) do nothing;

-- ---------- оценки ----------
-- Ступени и модификаторы — те же, что на странице: у «гениально»
-- плюсов не бывает, у «кринж-контента» минусов.
create table if not exists public.ratings (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  track_key   text not null check (char_length(track_key) between 1 and 600),
  tier        text not null check (tier in ('гениально', 'атлична', 'хорошечно',
                                            'нормас', 'ну такое', 'кринж-контент')),
  mod         text not null default '' check (mod in ('', '+', '++', '-', '- -')),
  rated_at    timestamptz,   -- время с устройства зрителя: только для порядка «последних оценок»
  created_at  timestamptz not null default now(),   -- время сервера: на него можно опираться
  updated_at  timestamptz not null default now(),
  primary key (user_id, track_key),
  check (not (tier = 'гениально' and mod in ('+', '++'))),
  check (not (tier = 'кринж-контент' and mod in ('-', '- -')))
);
alter table public.ratings enable row level security;

-- ---------- сердечки ----------
create table if not exists public.favs (
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  track_key   text not null check (char_length(track_key) between 1 and 600),
  created_at  timestamptz not null default now(),
  primary key (user_id, track_key)
);
alter table public.favs enable row level security;

-- Времена ставит сервер, а не тот, кто пишет.
create or replace function public.stamp_row()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
    new.user_id := old.user_id;
  end if;
  if tg_table_name = 'ratings' then
    new.updated_at := now();
    if new.rated_at is null or new.rated_at > now() then new.rated_at := now(); end if;
  end if;
  return new;
end $$;

drop trigger if exists ratings_stamp on public.ratings;
create trigger ratings_stamp before insert or update on public.ratings
  for each row execute function public.stamp_row();
drop trigger if exists favs_stamp on public.favs;
create trigger favs_stamp before insert or update on public.favs
  for each row execute function public.stamp_row();

-- Предел на строки одного зрителя: в архиве семь тысяч треков,
-- двадцати тысяч хватит с запасом, а забить базу мусором с одного
-- аккаунта не выйдет. Проверка раз на запрос, а не на каждую строку:
-- первая выгрузка оценок идёт пачками по пятьсот.
create or replace function public.limit_rows()
returns trigger language plpgsql set search_path = '' as $$
declare over boolean;
begin
  if tg_table_name = 'ratings' then
    select exists (select 1 from public.ratings r
                   where r.user_id in (select distinct user_id from fresh)
                   group by r.user_id having count(*) > 20000) into over;
  else
    select exists (select 1 from public.favs f
                   where f.user_id in (select distinct user_id from fresh)
                   group by f.user_id having count(*) > 20000) into over;
  end if;
  if over then raise exception 'too many rows for one user'; end if;
  return null;
end $$;

drop trigger if exists ratings_limit on public.ratings;
create trigger ratings_limit after insert on public.ratings
  referencing new table as fresh for each statement execute function public.limit_rows();
drop trigger if exists favs_limit on public.favs;
create trigger favs_limit after insert on public.favs
  referencing new table as fresh for each statement execute function public.limit_rows();

drop policy if exists ratings_own on public.ratings;
create policy ratings_own on public.ratings
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists favs_own on public.favs;
create policy favs_own on public.favs
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.ratings, public.favs from anon, authenticated;
grant select, insert, update, delete on public.ratings, public.favs to authenticated;

-- ---------- кто сейчас на сайте ----------
create table if not exists public.online (
  user_id  uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  seen_at  timestamptz not null default now()
);
alter table public.online enable row level security;

create or replace function public.stamp_online()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.seen_at := now();
  if tg_op = 'UPDATE' then new.user_id := old.user_id; end if;
  return new;
end $$;
drop trigger if exists online_stamp on public.online;
create trigger online_stamp before insert or update on public.online
  for each row execute function public.stamp_online();

-- Читать можно только свежие отметки: история заходов никому не нужна.
drop policy if exists online_read on public.online;
create policy online_read on public.online
  for select to anon, authenticated using (seen_at > now() - interval '10 minutes');
drop policy if exists online_mark_insert on public.online;
create policy online_mark_insert on public.online
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists online_mark_update on public.online;
create policy online_mark_update on public.online
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.online from anon, authenticated;
grant select on public.online to anon, authenticated;
grant insert, update on public.online to authenticated;

-- Человечки: кто отметился за последние две с половиной минуты.
-- Срок считает сервер — часы у зрителей врут.
create or replace view public.online_now with (security_invoker = true) as
  select o.user_id, p.name, p.login, p.avatar_url, p.color
  from public.online o join public.profiles p on p.id = o.user_id
  where o.seen_at > now() - interval '150 seconds';
revoke all on public.online_now from anon, authenticated;
grant select on public.online_now to anon, authenticated;
