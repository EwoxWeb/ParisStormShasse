-- =====================================================================
-- Migration v16 : historique détaillé et ajustement des points
-- À lancer UNE SEULE FOIS (après la v15).
-- =====================================================================

begin;

create table public.point_history (
  id              uuid primary key default gen_random_uuid(),
  event_key       text unique,
  settlement_id   uuid,
  event_type      text not null check (event_type in ('hunt', 'adjustment', 'legacy', 'reversal')),
  hunt_id         uuid,
  hunt_title      text,
  platform        text,
  user_id         uuid,
  twitch_name     text not null,
  twitch_avatar   text,
  guesses         integer[] not null default '{}',
  winning_result  integer,
  points          integer not null check (points <> 0),
  reason          text,
  created_at      timestamptz not null default now()
);

alter table public.point_history enable row level security;
revoke all on table public.point_history from public, anon, authenticated;
grant select on table public.point_history to anon, authenticated;
create policy "point_history_read" on public.point_history for select to anon, authenticated
  using (true);

-- Préserve les points archivés par v15. Les détails d'anciens paris déjà supprimés
-- ne sont plus disponibles ; ils sont identifiés comme historiques incomplets.
insert into public.point_history
  (event_key, event_type, hunt_id, hunt_title, user_id, twitch_name, twitch_avatar, points, created_at)
select 'legacy:' || hunt_id::text || ':' || player_key,
  'legacy', hunt_id, 'Shasse supprimée avant l’historique détaillé',
  user_id, twitch_name, twitch_avatar, points, archived_at
from public.hunt_points_archive
on conflict (event_key) do nothing;

create or replace function public.record_hunt_point_history()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_settlement_id uuid;
begin
  if tg_op = 'UPDATE' and old.status = 'finished' and old.result is not null then
    if new.status <> 'finished' or new.result is distinct from old.result then
      insert into public.point_history
        (event_key, settlement_id, event_type, hunt_id, hunt_title, platform, user_id,
         twitch_name, twitch_avatar, guesses, winning_result, points, reason, created_at)
      select 'reversal:' || gen_random_uuid()::text, h.settlement_id, 'reversal',
        old.id, old.title, old.platform, h.user_id, h.twitch_name, h.twitch_avatar,
        h.guesses, old.result, -h.points, 'Résultat annulé ou modifié par le streamer', now()
      from public.point_history h
      where h.event_type = 'hunt' and h.hunt_id = old.id
        and h.settlement_id is not null
        and not exists (
          select 1 from public.point_history r
          where r.event_type = 'reversal' and r.settlement_id = h.settlement_id
        );
      if new.status <> 'finished' or new.result is null then return new; end if;
    else
      if exists (
        select 1 from public.point_history h
        where h.event_type = 'hunt' and h.hunt_id = new.id
          and h.settlement_id is not null
          and not exists (
            select 1 from public.point_history r
            where r.event_type = 'reversal' and r.settlement_id = h.settlement_id
          )
      ) then
        update public.point_history h
        set hunt_title = new.title, platform = new.platform
        where h.event_type = 'hunt' and h.hunt_id = new.id
          and h.settlement_id is not null
          and not exists (
            select 1 from public.point_history r
            where r.event_type = 'reversal' and r.settlement_id = h.settlement_id
          );
        return new;
      end if;
    end if;
  end if;

  if new.status <> 'finished' or new.result is null or new.result_at is null
     or new.result_at < '2026-11-22T17:03:13.148Z'::timestamptz then
    return new;
  end if;

  v_settlement_id := gen_random_uuid();
  with ranked_bets as (
    select b.*,
      array_agg(b.guess) over (
        partition by coalesce(b.user_id::text, 'm:' || b.manual_player_id::text)
        order by b.slot rows between unbounded preceding and unbounded following
      ) as guesses,
      row_number() over (
        partition by coalesce(b.user_id::text, 'm:' || b.manual_player_id::text)
        order by abs(b.guess - new.result), b.created_at
      ) as bet_pick
    from public.bets b
    where b.hunt_id = new.id
  ),
  best_bets as (
    select * from ranked_bets where bet_pick = 1
  ),
  standings as (
    select *,
      row_number() over (order by abs(guess - new.result), created_at) as player_rank
    from best_bets
  )
  insert into public.point_history
    (event_key, settlement_id, event_type, hunt_id, hunt_title, platform, user_id, twitch_name,
     twitch_avatar, guesses, winning_result, points, created_at)
  select 'hunt:' || v_settlement_id::text || ':' || coalesce(user_id::text, 'm:' || manual_player_id::text),
    v_settlement_id,
    'hunt', new.id, new.title, new.platform, user_id, twitch_name,
    twitch_avatar, guesses, new.result,
    case when guess = new.result then 5
         when player_rank = 1 then 3
         when player_rank = 2 then 2
         when player_rank = 3 then 1
         else 0 end,
    new.result_at
  from standings
  where guess = new.result or player_rank <= 3;

  return new;
end;
$$;

create trigger hunts_record_point_history
  after insert or update on public.hunts
  for each row execute function public.record_hunt_point_history();

-- Enregistre les points des chasses déjà terminées avant la migration.
update public.hunts set title = title where status = 'finished';

create or replace function public.admin_adjust_player_points(
  p_twitch_name text,
  p_delta integer,
  p_reason text
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name text := nullif(btrim(p_twitch_name), '');
  v_reason text := nullif(btrim(p_reason), '');
  v_user_id uuid;
  v_avatar text;
begin
  if not (select public.is_admin()) then raise exception 'ADMIN_REQUIS'; end if;
  if v_name is null or char_length(v_name) > 25 then raise exception 'PSEUDO_INVALIDE'; end if;
  if p_delta is null or p_delta = 0 then raise exception 'AJUSTEMENT_INVALIDE'; end if;
  if v_reason is null or char_length(v_reason) > 500 then raise exception 'MOTIF_INVALIDE'; end if;

  select h.user_id, h.twitch_avatar into v_user_id, v_avatar
  from public.point_history h
  where lower(h.twitch_name) = lower(v_name) and h.user_id is not null
  order by h.created_at desc limit 1;
  if v_user_id is null then
    select b.user_id, b.twitch_avatar into v_user_id, v_avatar
    from public.bets b
    where lower(b.twitch_name) = lower(v_name) and b.user_id is not null
    order by b.created_at desc limit 1;
  end if;

  insert into public.point_history
    (event_type, user_id, twitch_name, twitch_avatar, points, reason)
  values ('adjustment', v_user_id, v_name, v_avatar, p_delta, v_reason);
end;
$$;

revoke execute on function public.admin_adjust_player_points(text, integer, text) from public, anon;
grant execute on function public.admin_adjust_player_points(text, integer, text) to authenticated;

commit;
