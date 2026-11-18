-- =====================================================================
--  Paris Shiny — schéma complet (INSTALLATION NEUVE uniquement)
--  Une chasse = une console (Switch ou 3DS), 2 paris max par compte et par chasse.
--  Si ta base existe déjà, utilise les fichiers migration-*.sql à la place.
--  Installation neuve : lance ce fichier, PUIS supabase/migration-v6-securite.sql (sécurité).
-- =====================================================================

create table public.hunts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 80),
  pokemon     text check (char_length(pokemon) <= 40),
  platform    text not null check (platform in ('switch', '3ds')),
  status      text not null default 'open' check (status in ('open', 'closed', 'finished')),
  closes_at   timestamptz,
  result      integer check (result > 0),
  created_at  timestamptz not null default now(),
  check (status <> 'finished' or result is not null)
);

create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create table public.bets (
  id            uuid primary key default gen_random_uuid(),
  hunt_id       uuid not null references public.hunts (id) on delete cascade,
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  twitch_name   text not null default '',
  twitch_avatar text,
  slot          smallint not null check (slot in (1, 2)),
  guess         integer not null check (guess between 1 and 10000000),
  created_at    timestamptz not null default now(),
  unique (hunt_id, user_id, slot),
  unique (hunt_id, user_id, guess)
);
create index bets_hunt_idx on public.bets (hunt_id);

-- Pseudo Twitch lu côté serveur + limite de 2 paris + pas deux fois le même nombre
create or replace function public.set_bet_identity()
returns trigger language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  new.user_id := auth.uid();
  select count(*) into n from public.bets where hunt_id = new.hunt_id and user_id = new.user_id;
  if n >= 2 then raise exception 'LIMITE_2_PARIS'; end if;
  if exists (select 1 from public.bets
             where hunt_id = new.hunt_id and user_id = new.user_id and guess = new.guess) then
    raise exception 'PARI_DEJA_JOUE';
  end if;
  new.slot := case when exists (select 1 from public.bets
                                where hunt_id = new.hunt_id and user_id = new.user_id and slot = 1)
                   then 2 else 1 end;
  select coalesce(u.raw_user_meta_data->>'preferred_username',
                  u.raw_user_meta_data->>'user_name',
                  u.raw_user_meta_data->>'name', 'inconnu'),
         coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture')
  into new.twitch_name, new.twitch_avatar
  from auth.users u where u.id = new.user_id;
  return new;
end;
$$;

create trigger bets_set_identity before insert on public.bets
  for each row execute function public.set_bet_identity();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

alter table public.hunts  enable row level security;
alter table public.admins enable row level security;
alter table public.bets   enable row level security;

create policy "hunts_read"   on public.hunts for select using (true);
create policy "hunts_insert" on public.hunts for insert with check (public.is_admin());
create policy "hunts_update" on public.hunts for update using (public.is_admin()) with check (public.is_admin());
create policy "hunts_delete" on public.hunts for delete using (public.is_admin());

create policy "admins_read_self" on public.admins for select using (user_id = auth.uid());

-- Paris : lecture limitée (voir ci-dessous), ajout si la chasse est ouverte, aucune modification
-- ni suppression par les joueurs (seul un admin peut supprimer).
-- chacun voit ses paris ; les admins voient tout ; tout devient visible une fois le résultat publié
create policy "bets_read" on public.bets for select using (
  user_id = auth.uid()
  or public.is_admin()
  or exists (select 1 from public.hunts h where h.id = hunt_id and h.status = 'finished')
);
create policy "bets_insert" on public.bets for insert
with check (
  auth.uid() is not null
  and user_id = auth.uid()
  and exists (
    select 1 from public.hunts h
    where h.id = hunt_id and h.status = 'open' and h.result is null
      and (h.closes_at is null or h.closes_at > now())
  )
);
create policy "bets_delete_admin" on public.bets for delete using (public.is_admin());

-- Devenir admin : connecte-toi une fois sur le site, puis (pseudo en minuscules) :
--   insert into public.admins (user_id)
--   select i.user_id from auth.identities i
--   where i.provider = 'twitch'
--     and lower(coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name', i.identity_data->>'name')) = 'TON_PSEUDO_TWITCH';
