-- =====================================================================
--  Migration v7 : paris ajoutés à la main + fusion avec les comptes Twitch
--  À lancer UNE SEULE FOIS (après la v6). Tout est dans une transaction.
--
--  - table manual_players : joueurs sans compte, créés par un admin à partir d'un pseudo
--  - un pari appartient soit à un compte Twitch, soit à un joueur manuel
--  - 3 fonctions réservées aux admins : ajouter un pari, lister les comptes Twitch connectés,
--    fusionner un joueur manuel avec un compte Twitch
-- =====================================================================

begin;

-- 1) joueurs ajoutés à la main
create table public.manual_players (
  id         uuid primary key default gen_random_uuid(),
  pseudo     text not null check (pseudo ~ '^[A-Za-z0-9_]{2,25}$'),
  created_at timestamptz not null default now()
);
create unique index manual_players_pseudo_key on public.manual_players (lower(pseudo));
alter table public.manual_players enable row level security;
revoke all on public.manual_players from anon, authenticated;
grant select on public.manual_players to authenticated;
create policy "manual_players_read" on public.manual_players for select to authenticated
  using ((select public.is_admin()));

-- 2) bets : un pari appartient à un compte OU à un joueur manuel
alter table public.bets alter column user_id drop not null;
alter table public.bets add column manual_player_id uuid references public.manual_players (id) on delete restrict;
alter table public.bets add constraint bets_owner_check
  check ((user_id is not null) <> (manual_player_id is not null));
alter table public.bets add constraint bets_manual_slot_key  unique (hunt_id, manual_player_id, slot);
alter table public.bets add constraint bets_manual_guess_key unique (hunt_id, manual_player_id, guess);

-- 3) trigger : laisse passer UNIQUEMENT les insertions faites par les fonctions admin ci-dessous
create or replace function public.set_bet_identity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  n integer;
  ident jsonb;
begin
  if current_setting('app.admin_insert', true) = 'on' and (select public.is_admin()) then
    return new;
  end if;

  new.user_id := auth.uid();
  if new.user_id is null then raise exception 'NON_CONNECTE'; end if;
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

-- 4) admin : ajouter un pari à partir d'un pseudo
--    - pseudo = compte Twitch déjà connecté -> pari rattaché à ce compte
--    - sinon -> joueur manuel (créé s'il n'existe pas)
create or replace function public.admin_add_bet(p_hunt uuid, p_pseudo text, p_guess integer)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_pseudo text := btrim(coalesce(p_pseudo, ''));
  v_hunt public.hunts%rowtype;
  v_uid uuid; v_ident jsonb; v_mid uuid;
  v_name text; v_avatar text; v_slot smallint; v_mode text;
begin
  if not (select public.is_admin()) then raise exception 'ADMIN_REQUIS'; end if;
  if v_pseudo !~ '^[A-Za-z0-9_]{2,25}$' then raise exception 'PSEUDO_INVALIDE'; end if;
  if p_guess is null or p_guess < 1 or p_guess > 10000000 then raise exception 'NOMBRE_INVALIDE'; end if;

  select * into v_hunt from public.hunts where id = p_hunt;
  if not found then raise exception 'SHASSE_INTROUVABLE'; end if;
  if v_hunt.status = 'finished' or v_hunt.result is not null then raise exception 'SHASSE_TERMINEE'; end if;

  select i.user_id, i.identity_data into v_uid, v_ident
  from auth.identities i
  where i.provider = 'twitch'
    and lower(coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name',
                       i.identity_data->>'name')) = lower(v_pseudo)
  limit 1;

  if v_uid is not null then
    v_mode := 'compte';
    v_name := coalesce(v_ident->>'preferred_username', v_ident->>'user_name', v_ident->>'name');
    v_avatar := coalesce(v_ident->>'avatar_url', v_ident->>'picture');
    if v_avatar is not null and v_avatar !~ '^https://static-cdn\.jtvnw\.net/' then v_avatar := null; end if;
    if (select count(*) from public.bets where hunt_id = p_hunt and user_id = v_uid) >= 2 then
      raise exception 'LIMITE_2_PARIS';
    end if;
    if exists (select 1 from public.bets where hunt_id = p_hunt and user_id = v_uid and guess = p_guess) then
      raise exception 'PARI_DEJA_JOUE';
    end if;
    v_slot := case when exists (select 1 from public.bets where hunt_id = p_hunt and user_id = v_uid and slot = 1)
                   then 2 else 1 end;
    perform set_config('app.admin_insert', 'on', true);
    insert into public.bets (hunt_id, user_id, manual_player_id, twitch_name, twitch_avatar, slot, guess)
    values (p_hunt, v_uid, null, v_name, v_avatar, v_slot, p_guess);
  else
    v_mode := 'manuel';
    select m.id into v_mid from public.manual_players m where lower(m.pseudo) = lower(v_pseudo);
    if v_mid is null then
      insert into public.manual_players (pseudo) values (v_pseudo) returning id into v_mid;
    end if;
    if (select count(*) from public.bets where hunt_id = p_hunt and manual_player_id = v_mid) >= 2 then
      raise exception 'LIMITE_2_PARIS';
    end if;
    if exists (select 1 from public.bets where hunt_id = p_hunt and manual_player_id = v_mid and guess = p_guess) then
      raise exception 'PARI_DEJA_JOUE';
    end if;
    v_slot := case when exists (select 1 from public.bets where hunt_id = p_hunt and manual_player_id = v_mid and slot = 1)
                   then 2 else 1 end;
    perform set_config('app.admin_insert', 'on', true);
    insert into public.bets (hunt_id, user_id, manual_player_id, twitch_name, twitch_avatar, slot, guess)
    values (p_hunt, null, v_mid, v_pseudo, null, v_slot, p_guess);
  end if;
  perform set_config('app.admin_insert', 'off', true);

  insert into public.audit_log (actor, action, table_name, row_id, detail)
  values (auth.uid(), 'ADMIN_ADD_BET', 'bets', null,
          jsonb_build_object('hunt', p_hunt, 'pseudo', v_pseudo, 'guess', p_guess, 'mode', v_mode));
  return v_mode;
end;
$$;

-- 5) admin : liste des comptes Twitch qui se sont connectés
create or replace function public.admin_list_twitch_accounts()
returns table (user_id uuid, pseudo text, avatar text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_admin()) then raise exception 'ADMIN_REQUIS'; end if;
  return query
  select i.user_id,
         coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name', i.identity_data->>'name'),
         case when coalesce(i.identity_data->>'avatar_url', i.identity_data->>'picture') ~ '^https://static-cdn\.jtvnw\.net/'
              then coalesce(i.identity_data->>'avatar_url', i.identity_data->>'picture') end,
         i.created_at
  from auth.identities i
  where i.provider = 'twitch'
  order by lower(coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name', i.identity_data->>'name'));
end;
$$;

-- 6) admin : fusionner un joueur manuel avec un compte Twitch (ses paris passent sur le compte)
create or replace function public.admin_merge_manual_player(p_manual uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record; v_ident jsonb; v_name text; v_avatar text; v_moved integer := 0; v_pseudo text;
begin
  if not (select public.is_admin()) then raise exception 'ADMIN_REQUIS'; end if;
  select m.pseudo into v_pseudo from public.manual_players m where m.id = p_manual;
  if v_pseudo is null then raise exception 'JOUEUR_MANUEL_INTROUVABLE'; end if;
  select i.identity_data into v_ident from auth.identities i
   where i.user_id = p_user and i.provider = 'twitch' limit 1;
  if v_ident is null then raise exception 'COMPTE_TWITCH_INTROUVABLE'; end if;

  v_name := coalesce(v_ident->>'preferred_username', v_ident->>'user_name', v_ident->>'name');
  v_avatar := coalesce(v_ident->>'avatar_url', v_ident->>'picture');
  if v_avatar is not null and v_avatar !~ '^https://static-cdn\.jtvnw\.net/' then v_avatar := null; end if;

  -- vérifie, shasse par shasse, que le total reste valide (max 2 paris, pas deux fois le même nombre)
  for r in select distinct b.hunt_id from public.bets b where b.manual_player_id = p_manual loop
    if (select count(*) from public.bets
        where hunt_id = r.hunt_id and (manual_player_id = p_manual or user_id = p_user)) > 2 then
      raise exception 'CONFLIT_TROP_DE_PARIS';
    end if;
    if exists (select 1 from public.bets
               where hunt_id = r.hunt_id and (manual_player_id = p_manual or user_id = p_user)
               group by guess having count(*) > 1) then
      raise exception 'CONFLIT_MEME_NOMBRE';
    end if;
  end loop;

  for r in select b.id, b.hunt_id from public.bets b where b.manual_player_id = p_manual order by b.created_at loop
    update public.bets
    set user_id = p_user, manual_player_id = null, twitch_name = v_name, twitch_avatar = v_avatar,
        slot = case when exists (select 1 from public.bets x
                                 where x.hunt_id = r.hunt_id and x.user_id = p_user and x.slot = 1)
                    then 2 else 1 end
    where id = r.id;
    v_moved := v_moved + 1;
  end loop;

  delete from public.manual_players where id = p_manual;

  insert into public.audit_log (actor, action, table_name, row_id, detail)
  values (auth.uid(), 'ADMIN_MERGE_PLAYER', 'manual_players', p_manual,
          jsonb_build_object('pseudo', v_pseudo, 'vers_compte', p_user, 'paris_deplaces', v_moved));
end;
$$;

-- 7) droits : réservé aux connectés (les fonctions vérifient elles-mêmes le rôle admin)
revoke execute on function public.admin_add_bet(uuid, text, integer),
                           public.admin_list_twitch_accounts(),
                           public.admin_merge_manual_player(uuid, uuid)
  from public, anon;
grant execute on function public.admin_add_bet(uuid, text, integer),
                          public.admin_list_twitch_accounts(),
                          public.admin_merge_manual_player(uuid, uuid)
  to authenticated;

commit;
