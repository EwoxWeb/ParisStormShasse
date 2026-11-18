-- =====================================================================
--  Migration v2 : double chasse Switch + 3DS
--  À lancer UNE SEULE FOIS sur ta base existante
--  (Supabase > SQL Editor > New query > Run)
--  Si tu repars d'une base vide, utilise schema.sql à la place.
-- =====================================================================

begin;

-- 1) hunts : un résultat par console
alter table public.hunts add column result_switch integer check (result_switch > 0);
alter table public.hunts add column result_3ds    integer check (result_3ds > 0);

-- l'ancien résultat unique est repris comme résultat Switch
update public.hunts set result_switch = result where result is not null;

-- supprime aussi l'ancienne contrainte « finished => result »
alter table public.hunts drop column result;

-- 2) bets : une console par pari, un pari par compte ET par console
alter table public.bets
  add column platform text not null default 'switch'
  check (platform in ('switch', '3ds'));          -- les anciens paris deviennent des paris Switch
alter table public.bets alter column platform drop default;

alter table public.bets drop constraint bets_hunt_id_user_id_key;
alter table public.bets add constraint bets_hunt_user_platform_key
  unique (hunt_id, user_id, platform);

-- 3) règle d'insertion : paris ouverts pour CETTE console seulement
drop policy "bets_insert" on public.bets;

create policy "bets_insert" on public.bets for insert
with check (
  auth.uid() is not null
  and user_id = auth.uid()
  and exists (
    select 1 from public.hunts h
    where h.id = hunt_id
      and h.status = 'open'
      and (h.closes_at is null or h.closes_at > now())
      and ((platform = 'switch' and h.result_switch is null)
        or (platform = '3ds'    and h.result_3ds    is null))
  )
);

commit;
