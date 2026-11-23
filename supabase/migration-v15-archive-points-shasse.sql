-- =====================================================================
-- Migration v15 : conserver les points lors de la suppression d'une shasse
-- À lancer UNE SEULE FOIS (après la v14).
-- =====================================================================

begin;

create table public.hunt_points_archive (
  hunt_id       uuid not null,
  player_key    text not null,
  user_id       uuid,
  twitch_name   text not null,
  twitch_avatar text,
  points        integer not null check (points between 1 and 5),
  archived_at   timestamptz not null default now(),
  primary key (hunt_id, player_key)
);

alter table public.hunt_points_archive enable row level security;
revoke all on table public.hunt_points_archive from public, anon, authenticated;
grant select on table public.hunt_points_archive to anon, authenticated;
create policy "hunt_points_archive_read" on public.hunt_points_archive for select to anon, authenticated
  using (true);

create or replace function public.archive_hunt_points_before_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.result is null or old.result_at is null
     or old.result_at < '2026-11-22T17:03:13.148Z'::timestamptz then
    return old;
  end if;

  with best_bets as (
    select user_id, manual_player_id, twitch_name, twitch_avatar, guess, created_at
    from (
      select b.*,
        row_number() over (
          partition by coalesce(b.user_id::text, 'm:' || b.manual_player_id::text)
          order by abs(b.guess - old.result), b.created_at
        ) as bet_pick
      from public.bets b
      where b.hunt_id = old.id
    ) ranked_bets
    where bet_pick = 1
  ),
  standings as (
    select *,
      row_number() over (order by abs(guess - old.result), created_at) as player_rank
    from best_bets
  )
  insert into public.hunt_points_archive
    (hunt_id, player_key, user_id, twitch_name, twitch_avatar, points)
  select old.id,
    coalesce(user_id::text, 'm:' || manual_player_id::text),
    user_id,
    twitch_name,
    twitch_avatar,
    case when guess = old.result then 5
         when player_rank = 1 then 3
         when player_rank = 2 then 2
         when player_rank = 3 then 1
         else 0 end
  from standings
  where guess = old.result or player_rank <= 3
  on conflict (hunt_id, player_key) do nothing;

  return old;
end;
$$;

create trigger hunts_archive_points_before_delete
  before delete on public.hunts
  for each row execute function public.archive_hunt_points_before_delete();

commit;
