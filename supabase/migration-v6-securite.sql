-- =====================================================================
--  Migration v6 : durcissement sécurité (à lancer UNE SEULE FOIS, après v5)
--
--  - pseudo Twitch lu dans auth.identities (non modifiable par l'utilisateur)
--    au lieu de raw_user_meta_data (modifiable via auth.updateUser)
--  - seuls les comptes Twitch peuvent parier ; date et identité du pari forcées par le serveur
--  - droits SQL réduits au strict minimum (défense en profondeur, en plus du RLS)
--  - journal d'audit des actions admin
--  - resynchronisation des pseudos déjà enregistrés
--  Tout est dans une transaction : en cas d'erreur, rien n'est modifié.
-- =====================================================================

begin;

-- 0) Garde-fou : chaque identité Twitch existante doit avoir un pseudo lisible
do $$
begin
  if exists (
    select 1 from auth.identities i
    where i.provider = 'twitch'
      and coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name',
                   i.identity_data->>'name', i.identity_data->>'nickname',
                   i.identity_data->>'slug', i.identity_data->>'full_name') is null
  ) then
    raise exception 'Migration annulee : une identite Twitch sans pseudo lisible dans auth.identities';
  end if;
end $$;

-- 1) Fonctions : search_path vide (anti-détournement) + identité fiable
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()));
$$;

create or replace function public.set_bet_identity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  n integer;
  ident jsonb;
begin
  new.user_id := auth.uid();
  if new.user_id is null then raise exception 'NON_CONNECTE'; end if;

  -- champs imposés par le serveur : le client ne peut pas les choisir
  new.id := gen_random_uuid();
  new.created_at := now();

  select i.identity_data into ident
  from auth.identities i
  where i.user_id = new.user_id and i.provider = 'twitch'
  limit 1;
  if ident is null then raise exception 'COMPTE_TWITCH_REQUIS'; end if;

  new.twitch_name := coalesce(ident->>'preferred_username', ident->>'user_name', ident->>'name',
                              ident->>'nickname', ident->>'slug', ident->>'full_name');
  if new.twitch_name is null then raise exception 'COMPTE_TWITCH_REQUIS'; end if;

  new.twitch_avatar := coalesce(ident->>'avatar_url', ident->>'picture');
  if new.twitch_avatar is not null and new.twitch_avatar !~ '^https://static-cdn\.jtvnw\.net/' then
    new.twitch_avatar := null;
  end if;

  select count(*) into n from public.bets where hunt_id = new.hunt_id and user_id = new.user_id;
  if n >= 2 then raise exception 'LIMITE_2_PARIS'; end if;
  if exists (select 1 from public.bets
             where hunt_id = new.hunt_id and user_id = new.user_id and guess = new.guess) then
    raise exception 'PARI_DEJA_JOUE';
  end if;
  new.slot := case when exists (select 1 from public.bets
                                where hunt_id = new.hunt_id and user_id = new.user_id and slot = 1)
                   then 2 else 1 end;
  return new;
end;
$$;

-- 2) Contraintes supplémentaires
alter table public.hunts add constraint hunts_result_max check (result is null or result <= 10000000);

-- 3) Règles RLS (rôles explicites : anon = visiteur, authenticated = connecté)
drop policy if exists "hunts_read"        on public.hunts;
drop policy if exists "hunts_insert"      on public.hunts;
drop policy if exists "hunts_update"      on public.hunts;
drop policy if exists "hunts_delete"      on public.hunts;
drop policy if exists "admins_read_self"  on public.admins;
drop policy if exists "bets_read"         on public.bets;
drop policy if exists "bets_insert"       on public.bets;
drop policy if exists "bets_delete_admin" on public.bets;

create policy "hunts_read"   on public.hunts for select to anon, authenticated using (true);
create policy "hunts_insert" on public.hunts for insert to authenticated with check ((select public.is_admin()));
create policy "hunts_update" on public.hunts for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "hunts_delete" on public.hunts for delete to authenticated using ((select public.is_admin()));

create policy "admins_read_self" on public.admins for select to authenticated
  using (user_id = (select auth.uid()));

create policy "bets_read" on public.bets for select to anon, authenticated using (
  user_id = (select auth.uid())
  or (select public.is_admin())
  or exists (select 1 from public.hunts h where h.id = hunt_id and h.status = 'finished')
);

create policy "bets_insert" on public.bets for insert to authenticated with check (
  (select auth.uid()) is not null
  and user_id = (select auth.uid())
  and exists (
    select 1 from public.hunts h
    where h.id = hunt_id and h.status = 'open' and h.result is null
      and (h.closes_at is null or h.closes_at > now())
  )
);

create policy "bets_delete_admin" on public.bets for delete to authenticated
  using ((select public.is_admin()));

-- 4) Droits SQL minimaux (le RLS reste la 2e barrière)
revoke all on public.hunts, public.bets, public.admins from anon, authenticated;
grant select on public.hunts to anon, authenticated;
grant insert, update, delete on public.hunts to authenticated;   -- réservé aux admins par le RLS
grant select on public.bets to anon, authenticated;
grant insert (hunt_id, guess) on public.bets to authenticated;   -- le client ne choisit que ces 2 colonnes
grant delete on public.bets to authenticated;                    -- réservé aux admins par le RLS
grant select on public.admins to authenticated;                  -- chacun ne voit que sa propre ligne

-- 5) Journal d'audit des actions admin
create table public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,
  action     text not null,
  table_name text not null,
  row_id     uuid,
  detail     jsonb
);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
create policy "audit_read" on public.audit_log for select to authenticated
  using ((select public.is_admin()));

create or replace function public.log_admin_action()
returns trigger language plpgsql security definer set search_path = '' as $$
declare d jsonb; rid uuid;
begin
  if tg_op = 'DELETE' then
    d := to_jsonb(old); rid := old.id;
  elsif tg_op = 'UPDATE' then
    d := jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)); rid := new.id;
  else
    d := to_jsonb(new); rid := new.id;
  end if;
  insert into public.audit_log (actor, action, table_name, row_id, detail)
  values (auth.uid(), tg_op, tg_table_name, rid, d);
  return null;
end;
$$;

create trigger hunts_audit after insert or update or delete on public.hunts
  for each row execute function public.log_admin_action();
create trigger bets_audit after delete on public.bets
  for each row execute function public.log_admin_action();

revoke execute on function public.set_bet_identity(), public.log_admin_action()
  from public, anon, authenticated;

-- 6) Resynchronise les pseudos déjà enregistrés avec les identités Twitch
update public.bets b
set twitch_name = coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name',
                           i.identity_data->>'name', i.identity_data->>'nickname',
                           i.identity_data->>'slug', i.identity_data->>'full_name', b.twitch_name),
    twitch_avatar = case
      when coalesce(i.identity_data->>'avatar_url', i.identity_data->>'picture') ~ '^https://static-cdn\.jtvnw\.net/'
      then coalesce(i.identity_data->>'avatar_url', i.identity_data->>'picture')
      else null end
from auth.identities i
where i.user_id = b.user_id and i.provider = 'twitch';

commit;
