-- =====================================================================
--  Migration v4 : une chasse = UNE console (Switch ou 3DS) + 2 paris max par chasse
--  À lancer UNE SEULE FOIS sur ta base existante (après v2 et v3).
--  Les doubles chasses existantes sont séparées en deux chasses :
--  « … (Switch) » et « … (3DS) », avec leurs paris et leurs résultats.
-- =====================================================================

begin;

alter table public.hunts
  add column if not exists platforms text[] not null default array['switch', '3ds'];

-- 1) hunts : une console et un résultat par chasse
alter table public.hunts add column platform text check (platform in ('switch', '3ds'));
alter table public.hunts add column result   integer check (result > 0);

-- 2) séparer les doubles chasses existantes
create temp table split_map on commit drop as
  select id as old_id, gen_random_uuid() as new_id
  from public.hunts where cardinality(platforms) = 2;

insert into public.hunts (id, title, pokemon, status, closes_at, created_at, platform, result)
select m.new_id, h.title || ' (3DS)', h.pokemon, h.status, h.closes_at, h.created_at, '3ds', h.result_3ds
from public.hunts h join split_map m on m.old_id = h.id;

update public.bets b set hunt_id = m.new_id
from split_map m where b.hunt_id = m.old_id and b.platform = '3ds';

update public.hunts h
set platform = 'switch', result = h.result_switch, title = h.title || ' (Switch)'
from split_map m where h.id = m.old_id;

-- chasses à une seule console
update public.hunts
set platform = platforms[1],
    result = case when platforms[1] = '3ds' then result_3ds else result_switch end
where platform is null;

update public.hunts set status = 'closed'   where status = 'finished' and result is null;
update public.hunts set status = 'finished' where result is not null and status <> 'finished';

-- 3) bets : plus de console, mais 2 emplacements par compte et par chasse
drop policy "bets_insert" on public.bets;
alter table public.bets drop column platform;

alter table public.bets add column slot smallint;
update public.bets b set slot = x.rn
from (select id, row_number() over (partition by hunt_id, user_id order by created_at) as rn
      from public.bets) x
where x.id = b.id;
alter table public.bets alter column slot set not null;
alter table public.bets add constraint bets_slot_check check (slot in (1, 2));
alter table public.bets add constraint bets_hunt_user_slot_key  unique (hunt_id, user_id, slot);
alter table public.bets add constraint bets_hunt_user_guess_key unique (hunt_id, user_id, guess);

-- 4) nettoyage de hunts
alter table public.hunts drop column result_switch, drop column result_3ds, drop column platforms;
alter table public.hunts alter column platform set not null;
alter table public.hunts add constraint hunts_finished_has_result
  check (status <> 'finished' or result is not null);

-- 5) pseudo Twitch + limite de 2 paris + pas deux fois le même nombre
create or replace function public.set_bet_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  new.user_id := auth.uid();
  select count(*) into n from public.bets
    where hunt_id = new.hunt_id and user_id = new.user_id;
  if n >= 2 then raise exception 'LIMITE_2_PARIS'; end if;
  if exists (select 1 from public.bets
             where hunt_id = new.hunt_id and user_id = new.user_id and guess = new.guess) then
    raise exception 'PARI_DEJA_JOUE';
  end if;
  new.slot := case when exists (select 1 from public.bets
                                where hunt_id = new.hunt_id and user_id = new.user_id and slot = 1)
                   then 2 else 1 end;
  select
    coalesce(u.raw_user_meta_data->>'preferred_username',
             u.raw_user_meta_data->>'user_name',
             u.raw_user_meta_data->>'name', 'inconnu'),
    coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture')
  into new.twitch_name, new.twitch_avatar
  from auth.users u where u.id = new.user_id;
  return new;
end;
$$;

-- 6) règle d'insertion : chasse ouverte, pas de résultat, avant la clôture
create policy "bets_insert" on public.bets for insert
with check (
  auth.uid() is not null
  and user_id = auth.uid()
  and exists (
    select 1 from public.hunts h
    where h.id = hunt_id
      and h.status = 'open'
      and h.result is null
      and (h.closes_at is null or h.closes_at > now())
  )
);

commit;
