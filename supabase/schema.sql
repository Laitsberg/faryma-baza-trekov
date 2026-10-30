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
--              менять цвет человечка, пару слов о себе и галочки, а
--              ник — только через set_name: чужой ник или логин она
--              не даст, иначе на главной можно было бы назваться
--              кем угодно.
--   ratings  — свои оценки. Меняет только владелец; видят все, пока
--              он сам не закрыл их в настройках (ratings_public).
--   favs     — сердечки. Так же, со своей галочкой (favs_public).
--   online   — кто сейчас на сайте: вошедший раз в минуту отмечается,
--              время ставит сервер. Читать могут все — это и есть
--              человечки на главной (через представление online_now).
--   role_grants — кто кем назначен, по логину Twitch. Роль в профиле
--              ставит сервер при входе: композитор входит — и сразу
--              «композитор». Через API эту таблицу не видно вовсе.
--   comments — общие комментарии и рецензии (kind) к трекам. Пишет
--              вошедший, удаляет автор или команда сайта.
--   claims   — заявки «это я в таблице»: зритель просит привязать к
--              себе имя из колонки «Кто», админ или композитор одобряет,
--              сверив ник на Twitch. Одно имя — одному аккаунту.
--   my_notifications, delete_me, taste_neighbors — уведомления, удаление
--              своего аккаунта и «близкие по вкусу».
--   track_counts, user_xp, top_xp — числа на карточках (сердечки и
--              комментарии трека), опыт зрителя для уровня в профиле и
--              десятка по опыту на главной.
--   set_name — свой ник на сайте вместо ника с Twitch.
--   comment_likes — сердечки комментариям и рецензиям. Кто именно
--              лайкнул, не видно никому, кроме него самого: наружу
--              отдаётся только число (comment_likes_for).
--   follows  — подписки: зритель держит у себя в кабинете тех, кто ему
--              интересен. Не взаимно, как у Twitch.
--   reports  — «сообщить о неточности» со страницы трека. Видят автор
--              и команда сайта, разбирают во вкладке «управление».
--   track_avgs — средняя оценка зрителей для карточек каталога.
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
  role        text not null default 'user' check (role in ('user', 'moder', 'admin', 'owner')),
  banned      boolean not null default false,
  created_at  timestamptz not null default now()
);
-- Для базы, созданной прошлой версией этого файла.
alter table public.profiles add column if not exists role text not null default 'user'
  check (role in ('user', 'moder', 'admin', 'owner'));
alter table public.profiles add column if not exists banned boolean not null default false;
-- Показывать ли свои оценки и избранное другим и не мелькать ли в
-- человечках — решает сам зритель. Оценки и избранное по умолчанию
-- открыты: так попросил заказчик (ниже, после таблиц).
alter table public.profiles add column if not exists ratings_public boolean not null default false;
alter table public.profiles add column if not exists favs_public boolean not null default true;
alter table public.profiles add column if not exists hide_online boolean not null default false;
-- Оценки сначала были закрыты по умолчанию, и галочку «показывать» за
-- день до перемены почти никто не трогал. Поэтому один раз, пока
-- умолчание старое, открываем их всем, кто уже входил, — дальше
-- умолчание новое, и повторный запуск этого файла ничьё решение не
-- перепишет: закрыл — останется закрытым.
do $$ begin
  if (select column_default from information_schema.columns
       where table_schema = 'public' and table_name = 'profiles' and column_name = 'ratings_public') = 'false' then
    update public.profiles set ratings_public = true;
    alter table public.profiles alter column ratings_public set default true;
  end if;
end $$;
-- Когда зритель последний раз смотрел уведомления.
alter table public.profiles add column if not exists notes_seen_at timestamptz;
-- Фон кабинета из аватара — виден и тем, кто открыл чужой профиль.
alter table public.profiles add column if not exists bg_avatar boolean not null default false;
-- Не показывать ссылку на свой канал Twitch в кабинете и профиле.
alter table public.profiles add column if not exists twitch_hidden boolean not null default false;
-- Ник сменён на сайте: вход через Twitch его больше не переписывает.
alter table public.profiles add column if not exists name_custom boolean not null default false;
-- Не показывать свои последние действия в публичном профиле.
alter table public.profiles add column if not exists activity_hidden boolean not null default false;
-- Привязанный плейлист Spotify — только его id из ссылки.
alter table public.profiles add column if not exists spotify_playlist text;
alter table public.profiles drop constraint if exists profiles_spotify_playlist_check;
alter table public.profiles add constraint profiles_spotify_playlist_check
  check (spotify_playlist is null or spotify_playlist ~ '^[A-Za-z0-9]{10,40}$');
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
grant update (color, bio, ratings_public, favs_public, hide_online, bg_avatar, twitch_hidden,
               activity_hidden, spotify_playlist) on public.profiles to authenticated;

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
        name       = case when public.profiles.name_custom then public.profiles.name else excluded.name end,
        avatar_url = excluded.avatar_url;
  perform public.apply_role(new.id);
  return new;
end $$;
revoke execute on function public.profile_from_auth() from public, anon, authenticated;

-- Свой ник на сайте. Сам столбец name клиенту не отдан: назваться можно
-- только через эту функцию, а она не даёт взять чужой ник или логин —
-- иначе на главной можно было бы назваться композитором. Пустой ник
-- возвращает тот, что на Twitch.
create or replace function public.set_name(p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := (select auth.uid()); n text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
        tw text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if n = '' then
    select left(coalesce(raw_user_meta_data->>'nickname', raw_user_meta_data->>'name'), 60) into tw
      from auth.users where id = me;
    update public.profiles set name = tw, name_custom = false where id = me;
    return tw;
  end if;
  if char_length(n) < 2 or char_length(n) > 30 then raise exception 'bad name length'; end if;
  if n ~ '[[:cntrl:]]' then raise exception 'bad name'; end if;
  if exists (select 1 from public.profiles
              where id <> me and (lower(name) = lower(n) or lower(login) = lower(n)))
     or exists (select 1 from public.role_grants g
              where g.twitch_login = lower(n)
                and not exists (select 1 from public.profiles p where p.id = me and lower(p.login) = g.twitch_login)) then
    raise exception 'name taken';
  end if;
  update public.profiles set name = n, name_custom = true where id = me;
  return n;
end $$;
revoke execute on function public.set_name(text) from public, anon;
grant execute on function public.set_name(text) to authenticated;

-- ---------- роли ----------
-- owner — композитор, всё; admin — команда сайта; moder — может
-- удалять комментарии и блокировать. Назначают по логину Twitch,
-- а при первом входе назначение привязывается к id на Twitch: логин
-- можно сменить или освободить, id — нет, и чужой человек под старым
-- логином роль не унаследует.
create table if not exists public.role_grants (
  twitch_login  text primary key check (twitch_login = lower(twitch_login)),
  role          text not null check (role in ('moder', 'admin', 'owner')),
  twitch_id     text unique,
  note          text,
  created_at    timestamptz not null default now()
);
alter table public.role_grants enable row level security;   -- политик нет: через API не видно
revoke all on public.role_grants from anon, authenticated;

-- Выставить профилю роль по назначениям. Зовётся при входе и при
-- любом изменении назначений.
create or replace function public.apply_role(uid uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare p record; g record;
begin
  select id, twitch_id, login into p from public.profiles where id = uid;
  if not found then return; end if;
  select * into g from public.role_grants
   where (twitch_id is not null and twitch_id = p.twitch_id)
      or (twitch_id is null and twitch_login = lower(p.login))
   order by twitch_id nulls last limit 1;
  if found then
    if g.twitch_id is null and p.twitch_id is not null then
      update public.role_grants set twitch_id = p.twitch_id where twitch_login = g.twitch_login;
    end if;
    update public.profiles set role = g.role where id = uid and role <> g.role;
  else
    update public.profiles set role = 'user' where id = uid and role <> 'user';
  end if;
end $$;
revoke execute on function public.apply_role(uuid) from public, anon, authenticated;

create or replace function public.role_grants_changed()
returns trigger language plpgsql security definer set search_path = '' as $$
declare u record;
begin
  for u in select pr.id from public.profiles pr
           where pr.role <> 'user'
              or lower(pr.login) in (select twitch_login from public.role_grants)
              or pr.twitch_id in (select twitch_id from public.role_grants where twitch_id is not null)
  loop
    perform public.apply_role(u.id);
  end loop;
  return null;
end $$;
revoke execute on function public.role_grants_changed() from public, anon, authenticated;
drop trigger if exists role_grants_apply on public.role_grants;
create trigger role_grants_apply after insert or update or delete on public.role_grants
  for each statement execute function public.role_grants_changed();

-- Кто сейчас пишет запрос и кем он назначен.
create or replace function public.my_role()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select role from public.profiles where id = (select auth.uid())), 'guest')
$$;
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.my_role() in ('moder', 'admin', 'owner')
$$;
grant execute on function public.my_role(), public.is_staff() to anon, authenticated;

-- Назначать из кабинета: композитор — модеров и админов, админ —
-- модеров. Композитора назначают только здесь, в SQL Editor, — так
-- его не снять и не подделать со страницы.
create or replace function public.grant_role(p_login text, p_role text)
returns void language plpgsql security definer set search_path = '' as $$
declare me text := public.my_role(); l text := lower(btrim(p_login)); cur text;
begin
  if l !~ '^[a-z0-9_]{3,25}$' then raise exception 'bad twitch login'; end if;
  select role into cur from public.role_grants where twitch_login = l;
  if cur = 'owner' or (cur = 'admin' and me <> 'owner') then raise exception 'not allowed'; end if;
  if p_role = 'user' then
    if me not in ('admin', 'owner') then raise exception 'not allowed'; end if;
    delete from public.role_grants where twitch_login = l;
    return;
  end if;
  if not ((me = 'owner' and p_role in ('moder', 'admin')) or (me = 'admin' and p_role = 'moder')) then
    raise exception 'not allowed';
  end if;
  insert into public.role_grants (twitch_login, role) values (l, p_role)
  on conflict (twitch_login) do update set role = excluded.role;
end $$;
revoke execute on function public.grant_role(text, text) from public, anon;
grant execute on function public.grant_role(text, text) to authenticated;

create or replace function public.list_roles()
returns table (twitch_login text, role text, name text, bound boolean)
language sql stable security definer set search_path = '' as $$
  select g.twitch_login, g.role, p.name, g.twitch_id is not null
  from public.role_grants g
  left join public.profiles p on p.twitch_id = g.twitch_id or (g.twitch_id is null and lower(p.login) = g.twitch_login)
  where public.my_role() in ('admin', 'owner')
  order by case g.role when 'owner' then 0 when 'admin' then 1 else 2 end, g.twitch_login
$$;
revoke execute on function public.list_roles() from public, anon;
grant execute on function public.list_roles() to authenticated;

-- Блокировка: заблокированный не пишет комментарии. Команду сайта
-- блокировать нельзя — только снять с неё роль.
create or replace function public.set_ban(p_user uuid, p_banned boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'not allowed'; end if;
  update public.profiles set banned = p_banned where id = p_user and role = 'user';
end $$;
revoke execute on function public.set_ban(uuid, boolean) from public, anon;
grant execute on function public.set_ban(uuid, boolean) to authenticated;

-- Кому роль положена с самого начала. Логин — как в адресе канала
-- twitch.tv/<логин>, строчными.
insert into public.role_grants (twitch_login, role, note) values
  ('farymacomposer', 'owner', 'композитор'),
  ('laitsberg', 'admin', 'разработка сайта')
on conflict (twitch_login) do nothing;

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
do $$ begin perform public.apply_role(id) from public.profiles; end $$;

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

-- Чужие оценки и сердечки видны, пока их хозяин не снял «показывать
-- мои оценки» / «показывать избранное» (по умолчанию стоят).
drop policy if exists ratings_public_read on public.ratings;
create policy ratings_public_read on public.ratings
  for select to anon, authenticated
  using (exists (select 1 from public.profiles p where p.id = ratings.user_id and p.ratings_public));
create index if not exists ratings_track on public.ratings (track_key);
drop policy if exists favs_public_read on public.favs;
create policy favs_public_read on public.favs
  for select to anon, authenticated
  using (exists (select 1 from public.profiles p where p.id = favs.user_id and p.favs_public));
create index if not exists favs_track on public.favs (track_key);

revoke all on public.ratings, public.favs from anon, authenticated;
grant select, insert, update, delete on public.ratings, public.favs to authenticated;
grant select on public.ratings, public.favs to anon;

-- ---------- комментарии ----------
create table if not exists public.comments (
  id          bigint generated always as identity primary key,
  track_key   text not null check (char_length(track_key) between 1 and 600),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 1500),
  parent_id   bigint references public.comments (id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table public.comments add column if not exists parent_id bigint references public.comments (id) on delete cascade;
-- Рецензия — тот же комментарий, но отдельной сущностью: у неё своя
-- ссылка (#r=id), и она длиннее. Ответом рецензия не бывает.
alter table public.comments add column if not exists kind text not null default 'comment';
alter table public.comments drop constraint if exists comments_kind_check;
alter table public.comments add constraint comments_kind_check check (kind in ('comment', 'review'));
alter table public.comments drop constraint if exists comments_body_check;
alter table public.comments add constraint comments_body_check
  check (char_length(btrim(body)) between 1 and (case when kind = 'review' then 6000 else 1500 end));
create index if not exists comments_reviews on public.comments (created_at desc) where kind = 'review';
create index if not exists comments_track on public.comments (track_key, created_at);
create index if not exists comments_parent on public.comments (parent_id);
alter table public.comments enable row level security;

-- Время — сервера; не больше двадцати комментариев за десять минут
-- с одного аккаунта; заблокированный не пишет вовсе.
create or replace function public.comment_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  new.body := btrim(new.body);
  if (select banned from public.profiles where id = new.user_id) then
    raise exception 'banned';
  end if;
  if (select count(*) from public.comments
      where user_id = new.user_id and created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'too many comments';
  end if;
  -- Ответ — к комментарию того же трека, и ветка одна: ответ на ответ
  -- встаёт под тот же исходный комментарий.
  if new.parent_id is not null then
    new.kind := 'comment';
    select coalesce(parent_id, id), track_key into new.parent_id, new.track_key
      from public.comments where id = new.parent_id;
    if new.parent_id is null then raise exception 'no such comment'; end if;
  end if;
  -- Рецензия — разбор, а не реплика: от 250 знаков и только от того, кто
  -- сам оценил трек. Проверка на вставке, а не ограничением столбца:
  -- рецензии, написанные до этого правила, остаются как были.
  if new.kind = 'review' then
    if char_length(new.body) < 250 then raise exception 'review too short'; end if;
    if not exists (select 1 from public.ratings
                    where user_id = new.user_id and track_key = new.track_key) then
      raise exception 'review needs rating';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.comment_guard() from public, anon, authenticated;
drop trigger if exists comments_guard on public.comments;
create trigger comments_guard before insert on public.comments
  for each row execute function public.comment_guard();

drop policy if exists comments_read on public.comments;
create policy comments_read on public.comments
  for select to anon, authenticated using (true);
drop policy if exists comments_write on public.comments;
create policy comments_write on public.comments
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments
  for delete to authenticated using (user_id = (select auth.uid()) or (select public.is_staff()));

revoke all on public.comments from anon, authenticated;
grant select on public.comments to anon, authenticated;
grant insert (track_key, body, parent_id, kind) on public.comments to authenticated;
grant delete on public.comments to authenticated;

-- ---------- лайки комментариев ----------
-- Обезличенные: кто лайкнул, видит только он сам, остальным —
-- число (comment_likes_for). Свой комментарий лайкнуть нельзя.
create table if not exists public.comment_likes (
  comment_id  bigint not null references public.comments (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (comment_id, user_id)
);
create index if not exists comment_likes_user on public.comment_likes (user_id);
alter table public.comment_likes enable row level security;

create or replace function public.like_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  if exists (select 1 from public.comments where id = new.comment_id and user_id = new.user_id) then
    raise exception 'own comment';
  end if;
  return new;
end $$;
revoke execute on function public.like_guard() from public, anon, authenticated;
drop trigger if exists comment_likes_guard on public.comment_likes;
create trigger comment_likes_guard before insert on public.comment_likes
  for each row execute function public.like_guard();

drop policy if exists comment_likes_own on public.comment_likes;
create policy comment_likes_own on public.comment_likes
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.comment_likes from anon, authenticated;
grant select, insert, delete on public.comment_likes to authenticated;

create or replace function public.comment_likes_for(p_track text)
returns table (comment_id bigint, n int, mine boolean)
language sql stable security definer set search_path = '' as $$
  select l.comment_id, count(*)::int, coalesce(bool_or(l.user_id = (select auth.uid())), false)
    from public.comment_likes l
    join public.comments c on c.id = l.comment_id
   where c.track_key = p_track
   group by l.comment_id
$$;
revoke execute on function public.comment_likes_for(text) from public;
grant execute on function public.comment_likes_for(text) to anon, authenticated;

-- ---------- заявки на свои заказы ----------
-- В таблице разносов заказчик записан так, как его назвали на стриме, и
-- это не всегда ник на Twitch. Поэтому привязку не угадываем, а просим:
-- зритель называет имя из колонки «Кто», админ сверяет его с ником на
-- Twitch и одобряет. Имя хранится строчными — «AndrLord» и «Andrlord» в
-- таблице один человек.
create table if not exists public.claims (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80 and name = lower(name)),
  shown       text check (char_length(shown) <= 80),        -- как написано в таблице
  note        text check (char_length(note) <= 300),        -- чем заявитель подтверждает
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  answer      text check (char_length(answer) <= 300),      -- ответ админа
  decided_by  uuid references public.profiles (id) on delete set null,
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
create unique index if not exists claims_taken on public.claims (name) where status = 'approved';
create unique index if not exists claims_once on public.claims (user_id, name) where status in ('pending', 'approved');
alter table public.claims enable row level security;

create or replace function public.claim_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.name := lower(btrim(new.name));
  new.status := 'pending';
  new.answer := null; new.decided_by := null; new.decided_at := null;
  new.created_at := now();
  if (select banned from public.profiles where id = new.user_id) then raise exception 'banned'; end if;
  if exists (select 1 from public.claims where name = new.name and status = 'approved') then
    raise exception 'name taken';
  end if;
  if (select count(*) from public.claims where user_id = new.user_id and status = 'pending') >= 10 then
    raise exception 'too many claims';
  end if;
  return new;
end $$;
revoke execute on function public.claim_guard() from public, anon, authenticated;
drop trigger if exists claims_guard on public.claims;
create trigger claims_guard before insert on public.claims
  for each row execute function public.claim_guard();

-- Одобренные видны всем: «кто заказал» на сайте потом можно будет вести
-- в профиль. Ждущие и отклонённые — только самому заявителю и тем, кто
-- их разбирает.
drop policy if exists claims_read on public.claims;
create policy claims_read on public.claims
  for select to anon, authenticated
  using (status = 'approved' or user_id = (select auth.uid()) or (select public.my_role()) in ('admin', 'owner'));
drop policy if exists claims_ask on public.claims;
create policy claims_ask on public.claims
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists claims_cancel on public.claims;
create policy claims_cancel on public.claims
  for delete to authenticated using (user_id = (select auth.uid()) and status = 'pending');

revoke all on public.claims from anon, authenticated;
grant select on public.claims to anon, authenticated;
grant insert (name, shown, note) on public.claims to authenticated;
grant delete on public.claims to authenticated;

-- Решение по заявке — админ или композитор. Одобренную можно и снять
-- (отклонить задним числом), если привязали не того.
create or replace function public.decide_claim(p_id bigint, p_ok boolean, p_answer text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  if public.my_role() not in ('admin', 'owner') then raise exception 'not allowed'; end if;
  select * into c from public.claims where id = p_id;
  if not found then raise exception 'no such claim'; end if;
  if p_ok and exists (select 1 from public.claims where name = c.name and status = 'approved' and id <> p_id) then
    raise exception 'name taken';
  end if;
  update public.claims
     set status = case when p_ok then 'approved' else 'rejected' end,
         answer = left(nullif(btrim(coalesce(p_answer, '')), ''), 300),
         decided_by = (select auth.uid()), decided_at = now()
   where id = p_id;
end $$;
revoke execute on function public.decide_claim(bigint, boolean, text) from public, anon;
grant execute on function public.decide_claim(bigint, boolean, text) to authenticated;

-- ---------- подписки ----------
-- Не дружба, а подписка: взаимности не нужно. Список своих подписок и
-- подписчиков видит сам зритель; другим — только числа (follow_stats).
create table if not exists public.follows (
  follower    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  followee    uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create index if not exists follows_followee on public.follows (followee);
alter table public.follows enable row level security;

create or replace function public.follow_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  if (select count(*) from public.follows where follower = new.follower) >= 1000 then
    raise exception 'too many follows';
  end if;
  return new;
end $$;
revoke execute on function public.follow_guard() from public, anon, authenticated;
drop trigger if exists follows_guard on public.follows;
create trigger follows_guard before insert on public.follows
  for each row execute function public.follow_guard();

drop policy if exists follows_read on public.follows;
create policy follows_read on public.follows
  for select to authenticated using (follower = (select auth.uid()) or followee = (select auth.uid()));
drop policy if exists follows_add on public.follows;
create policy follows_add on public.follows
  for insert to authenticated with check (follower = (select auth.uid()));
drop policy if exists follows_drop on public.follows;
create policy follows_drop on public.follows
  for delete to authenticated using (follower = (select auth.uid()));
revoke all on public.follows from anon, authenticated;
grant select, delete on public.follows to authenticated;
grant insert (followee) on public.follows to authenticated;

create or replace function public.follow_stats(p_user uuid)
returns table (followers int, following int, mine boolean)
language sql stable security definer set search_path = '' as $$
  select (select count(*)::int from public.follows where followee = p_user),
         (select count(*)::int from public.follows where follower = p_user),
         exists (select 1 from public.follows where follower = (select auth.uid()) and followee = p_user)
$$;
revoke execute on function public.follow_stats(uuid) from public;
grant execute on function public.follow_stats(uuid) to anon, authenticated;

-- ---------- сообщить о неточности ----------
-- Со страницы трека: не та обложка, не тот год, опечатка. Видят автор и
-- команда сайта; разбирают во вкладке «управление» (resolve_report).
create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  track_key   text not null check (char_length(track_key) between 1 and 600),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  what        text not null default 'other' check (what in ('cover', 'year', 'name', 'genre', 'link', 'other')),
  body        text not null check (char_length(btrim(body)) between 1 and 500),
  status      text not null default 'open' check (status in ('open', 'done')),
  decided_by  uuid references public.profiles (id) on delete set null,
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists reports_open on public.reports (created_at desc) where status = 'open';
alter table public.reports enable row level security;

create or replace function public.report_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  new.body := btrim(new.body);
  new.status := 'open'; new.decided_by := null; new.decided_at := null;
  if (select banned from public.profiles where id = new.user_id) then raise exception 'banned'; end if;
  if (select count(*) from public.reports
      where user_id = new.user_id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too many reports';
  end if;
  return new;
end $$;
revoke execute on function public.report_guard() from public, anon, authenticated;
drop trigger if exists reports_guard on public.reports;
create trigger reports_guard before insert on public.reports
  for each row execute function public.report_guard();

drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports
  for select to authenticated using (user_id = (select auth.uid()) or (select public.is_staff()));
drop policy if exists reports_add on public.reports;
create policy reports_add on public.reports
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists reports_drop on public.reports;
create policy reports_drop on public.reports
  for delete to authenticated using ((user_id = (select auth.uid()) and status = 'open') or (select public.is_staff()));
revoke all on public.reports from anon, authenticated;
grant select, delete on public.reports to authenticated;
grant insert (track_key, what, body) on public.reports to authenticated;

create or replace function public.resolve_report(p_id bigint, p_done boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'not allowed'; end if;
  update public.reports
     set status = case when p_done then 'done' else 'open' end,
         decided_by = case when p_done then (select auth.uid()) end,
         decided_at = case when p_done then now() end
   where id = p_id;
end $$;
revoke execute on function public.resolve_report(bigint, boolean) from public, anon;
grant execute on function public.resolve_report(bigint, boolean) to authenticated;

-- ---------- уведомления ----------
-- Что нового у зрителя: решения по его заявкам, ответы на его
-- комментарии и новые подписчики за последний месяц. «Новое» — позже,
-- чем он в последний раз открывал уведомления. У ответа — его id: по
-- уведомлению страница трека прокручивается прямо к нему.
-- Набор столбцов менялся, а «or replace» его поменять не может.
drop function if exists public.my_notifications();
create or replace function public.my_notifications()
returns table (kind text, at timestamptz, track_key text, body text, who text, who_login text,
               status text, claim text, answer text, fresh boolean, comment_id bigint)
language sql stable security definer set search_path = '' as $$
  with me as (select id, coalesce(notes_seen_at, 'epoch'::timestamptz) seen
              from public.profiles where id = (select auth.uid()))
  select 'claim', c.decided_at, null, null, null, null, c.status, coalesce(c.shown, c.name), c.answer,
         c.decided_at > me.seen, null::bigint
    from public.claims c, me
   where c.user_id = me.id and c.status <> 'pending' and c.decided_at > now() - interval '30 days'
  union all
  select 'reply', r.created_at, r.track_key, r.body, p.name, p.login, null, null, null,
         r.created_at > me.seen, r.id
    from public.comments r
    join public.comments mine on mine.id = r.parent_id
    join public.profiles p on p.id = r.user_id, me
   where mine.user_id = me.id and r.user_id <> me.id and r.created_at > now() - interval '30 days'
  union all
  select 'follow', f.created_at, null, null, p.name, p.login, null, null, null,
         f.created_at > me.seen, null
    from public.follows f
    join public.profiles p on p.id = f.follower, me
   where f.followee = me.id and f.created_at > now() - interval '30 days'
  order by 2 desc
  limit 50
$$;
create or replace function public.notifications_seen()
returns void language sql security definer set search_path = '' as $$
  update public.profiles set notes_seen_at = now() where id = (select auth.uid())
$$;
revoke execute on function public.my_notifications(), public.notifications_seen() from public, anon;
grant execute on function public.my_notifications(), public.notifications_seen() to authenticated;

-- ---------- удалить себя ----------
-- Зритель стирает аккаунт сам, без админа: профиль, оценки, сердечки,
-- комментарии, заявки и отметку «на сайте» — всё каскадом от auth.users.
create or replace function public.delete_me()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = (select auth.uid());
end $$;
revoke execute on function public.delete_me() from public, anon;
grant execute on function public.delete_me() to authenticated;

-- ---------- близкие по вкусу ----------
-- Среди тех, кто открыл свои оценки, — у кого больше всего совпадений
-- с тобой. Считает сервер: чужие оценки по одной на страницу не тянем.
-- Нужно хотя бы пять общих треков, иначе «совпадение» — случайность.
create or replace function public.rate_score(t text, m text)
returns numeric language sql immutable set search_path = '' as $$
  select (case t when 'гениально' then 10 when 'атлична' then 8 when 'хорошечно' then 6
                 when 'нормас' then 4 when 'ну такое' then 2 else 0 end)
       + (case m when '++' then .6 when '+' then .3 when '-' then -.3 when '- -' then -.6 else 0 end)
$$;
create or replace function public.taste_neighbors()
returns table (user_id uuid, name text, login text, avatar_url text, common int, same int, diff numeric)
language sql stable security definer set search_path = '' as $$
  select o.user_id, p.name, p.login, p.avatar_url,
         count(*)::int, count(*) filter (where o.tier = m.tier)::int,
         round(avg(abs(public.rate_score(o.tier, o.mod) - public.rate_score(m.tier, m.mod))) / 2, 2)
    from public.ratings m
    join public.ratings o on o.track_key = m.track_key and o.user_id <> m.user_id
    join public.profiles p on p.id = o.user_id and p.ratings_public
   where m.user_id = (select auth.uid())
   group by o.user_id, p.name, p.login, p.avatar_url
  having count(*) >= 5
   order by count(*) filter (where o.tier = m.tier)::numeric / count(*) desc, count(*) desc
   limit 10
$$;
revoke execute on function public.taste_neighbors() from public, anon;
grant execute on function public.taste_neighbors() to authenticated;

-- ---------- числа на карточках ----------
-- Сколько у трека сердечек и комментариев. Считаются все, в том числе
-- у тех, кто скрыл избранное: кто именно лайкнул, отсюда не узнать.
-- Свои сердечки спрашивающего не считаются — страница прибавляет их
-- сама, чтобы число менялось сразу по щелчку.
create or replace function public.track_counts()
returns table (track_key text, favs int, comments int)
language sql stable security definer set search_path = '' as $$
  select k, sum(f)::int, sum(c)::int from (
    select f.track_key k, 1 f, 0 c from public.favs f where f.user_id is distinct from (select auth.uid())
    union all
    select c.track_key, 0, 1 from public.comments c
  ) x group by k
$$;
revoke execute on function public.track_counts() from public;
grant execute on function public.track_counts() to anon, authenticated;

-- Средняя оценка зрителей для карточки каталога: по тем, кто открыл свои
-- оценки. Своя оценка спрашивающего сюда не входит — страница добавляет
-- её сама, и средняя меняется сразу по щелчку.
create or replace function public.track_avgs()
returns table (track_key text, n int, score numeric)
language sql stable security definer set search_path = '' as $$
  select r.track_key, count(*)::int, round(avg(public.rate_score(r.tier, r.mod)), 3)
    from public.ratings r
    join public.profiles p on p.id = r.user_id and p.ratings_public
   where r.user_id is distinct from (select auth.uid())
   group by r.track_key
$$;
revoke execute on function public.track_avgs() from public;
grant execute on function public.track_avgs() to anon, authenticated;

-- Опыт для уровня в профиле: каждая оценка и каждый комментарий — +10,
-- считает страница. Сюда — только сколько их; сами оценки этим не
-- открываются.
create or replace function public.user_xp(p_user uuid)
returns table (ratings int, comments int)
language sql stable security definer set search_path = '' as $$
  select (select count(*)::int from public.ratings where user_id = p_user),
         (select count(*)::int from public.comments where user_id = p_user)
$$;
revoke execute on function public.user_xp(uuid) from public;
grant execute on function public.user_xp(uuid) to anon, authenticated;

-- Десятка по опыту для главной: те же числа, что у user_xp, только
-- сразу у всех. Опыт — оценки и комментарии, без разбора, открыты ли
-- оценки: сколько их, видно и так, а какие — отсюда не узнать.
create or replace function public.top_xp()
returns table (user_id uuid, name text, login text, avatar_url text, color text, ratings int, comments int)
language sql stable security definer set search_path = '' as $$
  select p.id, p.name, p.login, p.avatar_url, p.color, coalesce(r.n, 0)::int, coalesce(c.n, 0)::int
    from public.profiles p
    left join (select user_id, count(*) n from public.ratings group by user_id) r on r.user_id = p.id
    left join (select user_id, count(*) n from public.comments group by user_id) c on c.user_id = p.id
   where coalesce(r.n, 0) + coalesce(c.n, 0) > 0
   order by coalesce(r.n, 0) + coalesce(c.n, 0) desc, p.created_at
   limit 10
$$;
revoke execute on function public.top_xp() from public;
grant execute on function public.top_xp() to anon, authenticated;

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
-- Свою строку видно всегда. Отметка — upsert, а у ON CONFLICT DO UPDATE
-- обновляемая строка обязана проходить и правило чтения: без этого тот,
-- кто ушёл дольше чем на 10 минут, падал на каждой отметке с ошибкой RLS
-- и больше не появлялся в человечках вовсе.
drop policy if exists online_read_own on public.online;
create policy online_read_own on public.online
  for select to authenticated using (user_id = (select auth.uid()));
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
  where o.seen_at > now() - interval '150 seconds' and not p.hide_online;
revoke all on public.online_now from anon, authenticated;
grant select on public.online_now to anon, authenticated;
