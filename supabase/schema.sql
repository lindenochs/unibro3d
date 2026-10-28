-- Unicycle Bros 3D online backend (Supabase/Postgres)
-- Run this whole file once in Supabase Dashboard -> SQL Editor.
-- The browser uses only the publishable/anon key. NEVER put a service-role key in public files.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  username_lower text generated always as (lower(username)) stored,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
create unique index if not exists profiles_username_ci_unique on public.profiles (username_lower);

create table if not exists public.game_saves (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friendships_not_self check (requester_id <> addressee_id),
  constraint friendships_direction_unique unique (requester_id, addressee_id)
);
create index if not exists friendships_requester_idx on public.friendships(requester_id, status);
create index if not exists friendships_addressee_idx on public.friendships(addressee_id, status);

create table if not exists public.match_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique check (room_code ~ '^[0-9]{9}$'),
  visibility text not null check (visibility in ('public','private')),
  host_id uuid not null references public.profiles(id) on delete cascade,
  max_players integer not null default 6 check (max_players between 2 and 6),
  course_key text not null default 'oval' check (course_key in ('oval','volcano','cyber','desert','rainbow')),
  difficulty_key text not null default 'normal' check (difficulty_key in ('easy','normal','hard','expert','ludicrous')),
  status text not null default 'waiting' check (status in ('waiting','racing','finished','closed')),
  scheduled_start_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.room_members (
  room_id uuid not null references public.match_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  char_key text not null default 'speedy' check (char_key in ('speedy','heavy','drift','phantom','apex')),
  hat_id text not null default 'hat_1' check (hat_id ~ '^hat_[0-9]+$'),
  flag_id text not null default 'flag_1' check (flag_id ~ '^flag_[0-9]+$'),
  primary key (room_id, user_id)
);
create index if not exists room_members_user_idx on public.room_members(user_id);

create table if not exists public.challenge_requests (
  id uuid primary key default gen_random_uuid(),
  challenger_id uuid not null references public.profiles(id) on delete cascade,
  challenged_id uuid not null references public.profiles(id) on delete cascade,
  room_id uuid references public.match_rooms(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','accepted','declined','expired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint challenges_not_self check (challenger_id <> challenged_id)
);
create index if not exists challenges_inbox_idx on public.challenge_requests(challenged_id, status, created_at desc);
create index if not exists challenges_outbox_idx on public.challenge_requests(challenger_id, status, created_at desc);

-- Automatically create a unique public profile when Supabase Auth creates a user.
create or replace function public.handle_new_unicycle_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
begin
  v_username := coalesce(new.raw_user_meta_data ->> 'username', '');
  if v_username !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters using letters, numbers, or underscores';
  end if;
  insert into public.profiles(id, username) values (new.id, v_username);
  insert into public.game_saves(user_id, payload) values (new.id, '{}'::jsonb);
  return new;
end;
$$;
drop trigger if exists on_unicycle_auth_user_created on auth.users;
create trigger on_unicycle_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_unicycle_user();

-- RLS helper. SECURITY DEFINER prevents recursive RLS checks on room_members.
create or replace function public.is_unicycle_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = auth.uid()
  );
$$;

alter table public.profiles enable row level security;
alter table public.game_saves enable row level security;
alter table public.friendships enable row level security;
alter table public.match_rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.challenge_requests enable row level security;

drop policy if exists profiles_read_signed_in on public.profiles;
create policy profiles_read_signed_in on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists saves_read_self on public.game_saves;
create policy saves_read_self on public.game_saves for select to authenticated using (user_id = auth.uid());
drop policy if exists saves_insert_self on public.game_saves;
create policy saves_insert_self on public.game_saves for insert to authenticated with check (user_id = auth.uid());
drop policy if exists saves_update_self on public.game_saves;
create policy saves_update_self on public.game_saves for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists friendships_read_involved on public.friendships;
create policy friendships_read_involved on public.friendships for select to authenticated using (requester_id = auth.uid() or addressee_id = auth.uid());
drop policy if exists rooms_read_members on public.match_rooms;
create policy rooms_read_members on public.match_rooms for select to authenticated using (public.is_unicycle_room_member(id));
drop policy if exists room_members_read_members on public.room_members;
create policy room_members_read_members on public.room_members for select to authenticated using (public.is_unicycle_room_member(room_id));
drop policy if exists challenges_read_involved on public.challenge_requests;
create policy challenges_read_involved on public.challenge_requests for select to authenticated using (challenger_id = auth.uid() or challenged_id = auth.uid());

-- Explicit least-privilege grants. All friend/room mutations happen through checked RPCs below.
grant select on public.profiles to authenticated;
grant update (last_seen) on public.profiles to authenticated;
grant select, insert, update on public.game_saves to authenticated;
grant select on public.friendships, public.challenge_requests to authenticated;
grant select on public.match_rooms, public.room_members to authenticated;
revoke all on function public.is_unicycle_room_member(uuid) from public;
grant execute on function public.is_unicycle_room_member(uuid) to authenticated;

create or replace function public.send_friend_request(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_existing public.friendships%rowtype;
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if p_target_id is null or p_target_id = v_me then raise exception 'You cannot add yourself'; end if;
  if not exists(select 1 from public.profiles where id = p_target_id) then raise exception 'Profile not found'; end if;
  select * into v_existing from public.friendships f
    where (f.requester_id=v_me and f.addressee_id=p_target_id) or (f.requester_id=p_target_id and f.addressee_id=v_me)
    order by (f.status='accepted') desc, f.created_at desc limit 1;
  if found and v_existing.status='accepted' then raise exception 'Already friends'; end if;
  if found and v_existing.status='pending' then raise exception 'A friend request is already pending'; end if;
  delete from public.friendships f
    where ((f.requester_id=v_me and f.addressee_id=p_target_id) or (f.requester_id=p_target_id and f.addressee_id=v_me)) and f.status='declined';
  insert into public.friendships(requester_id, addressee_id, status) values (v_me, p_target_id, 'pending') returning * into v_existing;
  return jsonb_build_object('id',v_existing.id,'status',v_existing.status);
end; $$;

create or replace function public.respond_friend_request(p_request_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_req public.friendships%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into v_req from public.friendships where id=p_request_id for update;
  if not found or v_req.addressee_id <> auth.uid() or v_req.status <> 'pending' then raise exception 'This request is no longer available'; end if;
  update public.friendships set status=case when p_accept then 'accepted' else 'declined' end, updated_at=now() where id=p_request_id returning * into v_req;
  return jsonb_build_object('id',v_req.id,'status',v_req.status);
end; $$;

create or replace function public.remove_unicycle_friend(p_friend_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.friendships f where f.status='accepted' and
    ((f.requester_id=auth.uid() and f.addressee_id=p_friend_id) or (f.requester_id=p_friend_id and f.addressee_id=auth.uid()));
  return true;
end; $$;

create or replace function public.create_private_room(
  p_course_key text default 'oval', p_difficulty_key text default 'normal',
  p_char_key text default 'speedy', p_hat_id text default 'hat_1', p_flag_id text default 'flag_1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id uuid; v_code text; v_course text; v_diff text;
  v_char text; v_hat text; v_flag text; v_room public.match_rooms%rowtype; v_attempt int;
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  v_course := case when p_course_key in ('oval','volcano','cyber','desert','rainbow') then p_course_key else 'oval' end;
  v_diff := case when p_difficulty_key in ('easy','normal','hard','expert','ludicrous') then p_difficulty_key else 'normal' end;
  v_char := case when p_char_key in ('speedy','heavy','drift','phantom','apex') then p_char_key else 'speedy' end;
  v_hat := case when p_hat_id ~ '^hat_[0-9]+$' then p_hat_id else 'hat_1' end;
  v_flag := case when p_flag_id ~ '^flag_[0-9]+$' then p_flag_id else 'flag_1' end;
  for v_attempt in 1..30 loop
    v_code := lpad(floor(random()*1000000000)::bigint::text, 9, '0');
    if not exists(select 1 from public.match_rooms where room_code=v_code) then exit; end if;
    v_code := null;
  end loop;
  if v_code is null then raise exception 'Could not generate a room code; please retry'; end if;
  insert into public.match_rooms(room_code,visibility,host_id,course_key,difficulty_key) values(v_code,'private',v_me,v_course,v_diff) returning * into v_room;
  insert into public.room_members(room_id,user_id,char_key,hat_id,flag_id) values(v_room.id,v_me,v_char,v_hat,v_flag);
  return jsonb_build_object('id',v_room.id,'room_code',v_room.room_code,'visibility',v_room.visibility,'host_id',v_room.host_id,'course_key',v_room.course_key,'difficulty_key',v_room.difficulty_key,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at,'max_players',v_room.max_players);
end; $$;

create or replace function public.join_private_room(
  p_room_code text, p_char_key text default 'speedy', p_hat_id text default 'hat_1', p_flag_id text default 'flag_1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_room public.match_rooms%rowtype; v_count int;
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if p_room_code !~ '^[0-9]{9}$' then raise exception 'Enter the 9-digit room code'; end if;
  select * into v_room from public.match_rooms where room_code=p_room_code and visibility='private' for update;
  if not found or v_room.status <> 'waiting' then raise exception 'Room not found or already started'; end if;
  select count(*) into v_count from public.room_members where room_id=v_room.id;
  if not exists(select 1 from public.room_members where room_id=v_room.id and user_id=v_me) and v_count >= v_room.max_players then raise exception 'Room is full'; end if;
  insert into public.room_members(room_id,user_id,char_key,hat_id,flag_id) values(v_room.id,v_me,
    case when p_char_key in ('speedy','heavy','drift','phantom','apex') then p_char_key else 'speedy' end,
    case when p_hat_id ~ '^hat_[0-9]+$' then p_hat_id else 'hat_1' end,
    case when p_flag_id ~ '^flag_[0-9]+$' then p_flag_id else 'flag_1' end)
  on conflict(room_id,user_id) do update set last_seen=now(), char_key=excluded.char_key, hat_id=excluded.hat_id, flag_id=excluded.flag_id;
  return jsonb_build_object('id',v_room.id,'room_code',v_room.room_code,'visibility',v_room.visibility,'host_id',v_room.host_id,'course_key',v_room.course_key,'difficulty_key',v_room.difficulty_key,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at,'max_players',v_room.max_players);
end; $$;

create or replace function public.join_public_match(
  p_course_key text default 'oval', p_difficulty_key text default 'normal',
  p_char_key text default 'speedy', p_hat_id text default 'hat_1', p_flag_id text default 'flag_1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_room public.match_rooms%rowtype; v_room_id uuid; v_code text; v_attempt int;
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  perform pg_advisory_xact_lock(hashtext('unicycle_bros_public_matchmaking'));
  -- Evict abandoned members from waiting public rooms so old browser tabs do not fill matchmaking forever.
  delete from public.room_members rm using public.match_rooms mr
    where rm.room_id=mr.id and mr.visibility='public' and mr.status='waiting' and rm.last_seen < now()-interval '60 seconds';
  select mr.id into v_room_id from public.match_rooms mr
    where mr.visibility='public' and mr.status='waiting'
      and (select count(*) from public.room_members rm where rm.room_id=mr.id) < mr.max_players
    order by (select count(*) from public.room_members rm where rm.room_id=mr.id) desc, mr.created_at asc
    limit 1 for update of mr skip locked;
  if v_room_id is null then
    for v_attempt in 1..30 loop
      v_code := lpad(floor(random()*1000000000)::bigint::text,9,'0');
      if not exists(select 1 from public.match_rooms where room_code=v_code) then exit; end if;
      v_code := null;
    end loop;
    if v_code is null then raise exception 'Could not create a matchmaking lobby'; end if;
    insert into public.match_rooms(room_code,visibility,host_id,
      course_key,difficulty_key)
    values(v_code,'public',v_me,
      case when p_course_key in ('oval','volcano','cyber','desert','rainbow') then p_course_key else 'oval' end,
      case when p_difficulty_key in ('easy','normal','hard','expert','ludicrous') then p_difficulty_key else 'normal' end)
    returning * into v_room;
    v_room_id := v_room.id;
  else
    select * into v_room from public.match_rooms where id=v_room_id;
  end if;
  insert into public.room_members(room_id,user_id,char_key,hat_id,flag_id) values(v_room_id,v_me,
    case when p_char_key in ('speedy','heavy','drift','phantom','apex') then p_char_key else 'speedy' end,
    case when p_hat_id ~ '^hat_[0-9]+$' then p_hat_id else 'hat_1' end,
    case when p_flag_id ~ '^flag_[0-9]+$' then p_flag_id else 'flag_1' end)
  on conflict(room_id,user_id) do update set last_seen=now(), char_key=excluded.char_key, hat_id=excluded.hat_id, flag_id=excluded.flag_id;
  select * into v_room from public.match_rooms where id=v_room_id;
  return jsonb_build_object('id',v_room.id,'room_code',v_room.room_code,'visibility',v_room.visibility,'host_id',v_room.host_id,'course_key',v_room.course_key,'difficulty_key',v_room.difficulty_key,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at,'max_players',v_room.max_players);
end; $$;

create or replace function public.get_room_roster(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.room_members where room_id=p_room_id and user_id=auth.uid()) then raise exception 'You are not in this room'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',rm.user_id,'username',p.username,'char_key',rm.char_key,'hat_id',rm.hat_id,'flag_id',rm.flag_id,'last_seen',rm.last_seen) order by rm.joined_at), '[]'::jsonb)
    into v_result from public.room_members rm join public.profiles p on p.id=rm.user_id
    where rm.room_id=p_room_id and rm.last_seen > now()-interval '90 seconds';
  return v_result;
end; $$;

create or replace function public.touch_match_room(p_room_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  update public.room_members set last_seen=now() where room_id=p_room_id and user_id=auth.uid();
  return found;
end; $$;

create or replace function public.start_room_race(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_room public.match_rooms%rowtype; v_count int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into v_room from public.match_rooms where id=p_room_id for update;
  if not found or not exists(select 1 from public.room_members where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room not found'; end if;
  if v_room.visibility='private' and v_room.host_id<>auth.uid() then raise exception 'Only the host can start this private race'; end if;
  if v_room.status='racing' and v_room.scheduled_start_at is not null then
    return jsonb_build_object('id',v_room.id,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at);
  end if;
  if v_room.status<>'waiting' then raise exception 'This room is not waiting for racers'; end if;
  select count(*) into v_count from public.room_members where room_id=p_room_id and last_seen>now()-interval '90 seconds';
  if v_room.visibility='public' and v_count < 4 then raise exception 'Public matchmaking requires at least four racers'; end if;
  if v_room.visibility='private' and v_count < 2 then raise exception 'At least two racers must be in the room'; end if;
  update public.match_rooms set status='racing',scheduled_start_at=now()+interval '5 seconds' where id=p_room_id returning * into v_room;
  return jsonb_build_object('id',v_room.id,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at);
end; $$;

create or replace function public.leave_match_room(p_room_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_room public.match_rooms%rowtype;
begin
  if auth.uid() is null then return false; end if;
  select * into v_room from public.match_rooms where id=p_room_id for update;
  if not found or not exists(select 1 from public.room_members where room_id=p_room_id and user_id=auth.uid()) then return false; end if;
  if v_room.host_id=auth.uid() and v_room.visibility='private' then
    delete from public.match_rooms where id=p_room_id;
  else
    delete from public.room_members where room_id=p_room_id and user_id=auth.uid();
    if v_room.host_id=auth.uid() and v_room.visibility='public' then
      update public.match_rooms set host_id=(select user_id from public.room_members where room_id=p_room_id order by joined_at limit 1)
        where id=p_room_id and exists(select 1 from public.room_members where room_id=p_room_id);
    end if;
    if not exists(select 1 from public.room_members where room_id=p_room_id) then delete from public.match_rooms where id=p_room_id; end if;
  end if;
  return true;
end; $$;

create or replace function public.send_friend_challenge(
  p_target_id uuid, p_course_key text default 'oval', p_difficulty_key text default 'normal',
  p_char_key text default 'speedy', p_hat_id text default 'hat_1', p_flag_id text default 'flag_1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_room jsonb; v_room_id uuid; v_challenge public.challenge_requests%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_target_id=auth.uid() then raise exception 'You cannot challenge yourself'; end if;
  if not exists(select 1 from public.friendships f where f.status='accepted' and ((f.requester_id=auth.uid() and f.addressee_id=p_target_id) or (f.requester_id=p_target_id and f.addressee_id=auth.uid()))) then raise exception 'You can only challenge an accepted friend'; end if;
  if not exists(select 1 from public.profiles p where p.id=p_target_id and p.last_seen>now()-interval '60 seconds') then raise exception 'That friend is not online right now'; end if;
  v_room := public.create_private_room(p_course_key,p_difficulty_key,p_char_key,p_hat_id,p_flag_id);
  v_room_id := (v_room->>'id')::uuid;
  insert into public.challenge_requests(challenger_id,challenged_id,room_id,status) values(auth.uid(),p_target_id,v_room_id,'pending') returning * into v_challenge;
  return jsonb_build_object('id',v_challenge.id,'room',v_room,'status',v_challenge.status);
end; $$;

create or replace function public.respond_to_challenge(
  p_challenge_id uuid, p_accept boolean, p_char_key text default 'speedy', p_hat_id text default 'hat_1', p_flag_id text default 'flag_1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_req public.challenge_requests%rowtype; v_room public.match_rooms%rowtype; v_count int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into v_req from public.challenge_requests where id=p_challenge_id for update;
  if not found or v_req.challenged_id<>auth.uid() or v_req.status<>'pending' then raise exception 'This challenge is no longer available'; end if;
  if not p_accept then
    update public.challenge_requests set status='declined',updated_at=now() where id=p_challenge_id;
    if v_req.room_id is not null then update public.match_rooms set status='closed' where id=v_req.room_id and status='waiting'; end if;
    return jsonb_build_object('status','declined');
  end if;
  if v_req.room_id is null then raise exception 'The host room has expired'; end if;
  select * into v_room from public.match_rooms where id=v_req.room_id for update;
  if not found or v_room.status<>'waiting' then raise exception 'The host room is no longer available'; end if;
  select count(*) into v_count from public.room_members where room_id=v_room.id;
  if not exists(select 1 from public.room_members where room_id=v_room.id and user_id=auth.uid()) and v_count>=v_room.max_players then raise exception 'That room is full'; end if;
  insert into public.room_members(room_id,user_id,char_key,hat_id,flag_id) values(v_room.id,auth.uid(),
    case when p_char_key in ('speedy','heavy','drift','phantom','apex') then p_char_key else 'speedy' end,
    case when p_hat_id ~ '^hat_[0-9]+$' then p_hat_id else 'hat_1' end,
    case when p_flag_id ~ '^flag_[0-9]+$' then p_flag_id else 'flag_1' end)
  on conflict(room_id,user_id) do update set last_seen=now(),char_key=excluded.char_key,hat_id=excluded.hat_id,flag_id=excluded.flag_id;
  update public.challenge_requests set status='accepted',updated_at=now() where id=p_challenge_id;
  return jsonb_build_object('status','accepted','room',jsonb_build_object('id',v_room.id,'room_code',v_room.room_code,'visibility',v_room.visibility,'host_id',v_room.host_id,'course_key',v_room.course_key,'difficulty_key',v_room.difficulty_key,'status',v_room.status,'scheduled_start_at',v_room.scheduled_start_at,'max_players',v_room.max_players));
end; $$;

-- RPC permissions: functions expose only the requested action and verify auth.uid() internally.
revoke all on function public.send_friend_request(uuid) from public;
revoke all on function public.respond_friend_request(uuid,boolean) from public;
revoke all on function public.remove_unicycle_friend(uuid) from public;
revoke all on function public.create_private_room(text,text,text,text,text) from public;
revoke all on function public.join_private_room(text,text,text,text) from public;
revoke all on function public.join_public_match(text,text,text,text,text) from public;
revoke all on function public.get_room_roster(uuid) from public;
revoke all on function public.touch_match_room(uuid) from public;
revoke all on function public.start_room_race(uuid) from public;
revoke all on function public.leave_match_room(uuid) from public;
revoke all on function public.send_friend_challenge(uuid,text,text,text,text,text) from public;
revoke all on function public.respond_to_challenge(uuid,boolean,text,text,text) from public;
grant execute on function public.send_friend_request(uuid) to authenticated;
grant execute on function public.respond_friend_request(uuid,boolean) to authenticated;
grant execute on function public.remove_unicycle_friend(uuid) to authenticated;
grant execute on function public.create_private_room(text,text,text,text,text) to authenticated;
grant execute on function public.join_private_room(text,text,text,text) to authenticated;
grant execute on function public.join_public_match(text,text,text,text,text) to authenticated;
grant execute on function public.get_room_roster(uuid) to authenticated;
grant execute on function public.touch_match_room(uuid) to authenticated;
grant execute on function public.start_room_race(uuid) to authenticated;
grant execute on function public.leave_match_room(uuid) to authenticated;
grant execute on function public.send_friend_challenge(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.respond_to_challenge(uuid,boolean,text,text,text) to authenticated;
