-- =====================================================================
--  Migration v5 : paris cachés
--  Chaque joueur ne voit que ses propres paris. Les admins voient tout.
--  Une fois le résultat publié (chasse terminée), tous les paris deviennent
--  visibles pour le classement.
--  À lancer UNE SEULE FOIS (SQL Editor > Run).
-- =====================================================================

begin;

drop policy "bets_read" on public.bets;

create policy "bets_read" on public.bets for select using (
  user_id = auth.uid()
  or public.is_admin()
  or exists (select 1 from public.hunts h where h.id = hunt_id and h.status = 'finished')
);

commit;
