-- =====================================================================
--  Migration v3 : choisir les consoles d'une chasse (Switch, 3DS ou les deux)
--  À lancer UNE SEULE FOIS, après la migration v2.
--  Les chasses existantes restent des doubles chasses (Switch + 3DS).
-- =====================================================================

begin;

alter table public.hunts
  add column platforms text[] not null default array['switch', '3ds']
  check (platforms <> '{}' and platforms <@ array['switch', '3ds']);

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
      and platform = any (h.platforms)
      and ((platform = 'switch' and h.result_switch is null)
        or (platform = '3ds'    and h.result_3ds    is null))
  )
);

commit;
