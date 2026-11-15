-- =====================================================================
--  Paris Shiny — schéma Supabase
--  À coller en entier dans Supabase > SQL Editor > New query > Run
-- =====================================================================

-- ---------- Tables ---------------------------------------------------

create table public.hunts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 80),
  pokemon     text check (char_length(pokemon) <= 40),
  status      text not null default 'open'
              check (status in ('open', 'closed', 'finished')),
  closes_at   timestamptz,                       -- clôture automatique (optionnelle)
  result      integer check (result > 0),        -- nombre final de rencontres
  created_at  timestamptz not null default now(),
  check (status <> 'finished' or result is not null)
);

-- Liste des admins (gérée uniquement depuis le SQL Editor)
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create table public.bets (
  id            uuid primary key default gen_random_uuid(),
  hunt_id       uuid not null references public.hunts (id) on delete cascade,
  user_id       uuid not null default auth.uid()
                references auth.users (id) on delete cascade,
  twitch_name   text not null default '',
  twitch_avatar text,
  guess         integer not null check (guess between 1 and 10000000),
  created_at    timestamptz not null default now(),
  unique (hunt_id, user_id)                      -- un seul pari par compte et par chasse
);

create index bets_hunt_idx on public.bets (hunt_id);

-- ---------- Sécurité du pseudo ---------------------------------------
-- Le pseudo vient TOUJOURS du compte Twitch connecté, jamais du navigateur.
-- Impossible de parier sous le nom de quelqu'un d'autre.

create or replace function public.set_bet_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.user_id := auth.uid();
  select
    coalesce(u.raw_user_meta_data->>'preferred_username',
             u.raw_user_meta_data->>'user_name',
             u.raw_user_meta_data->>'name',
             'inconnu'),
    coalesce(u.raw_user_meta_data->>'avatar_url',
             u.raw_user_meta_data->>'picture')
  into new.twitch_name, new.twitch_avatar
  from auth.users u
  where u.id = new.user_id;
  return new;
end;
$$;

create trigger bets_set_identity
  before insert on public.bets
  for each row execute function public.set_bet_identity();

-- ---------- Helper admin ---------------------------------------------

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- Row Level Security ---------------------------------------

alter table public.hunts  enable row level security;
alter table public.admins enable row level security;
alter table public.bets   enable row level security;

-- hunts : lecture publique, écriture admin uniquement
create policy "hunts_read"   on public.hunts for select using (true);
create policy "hunts_insert" on public.hunts for insert with check (public.is_admin());
create policy "hunts_update" on public.hunts for update using (public.is_admin()) with check (public.is_admin());
create policy "hunts_delete" on public.hunts for delete using (public.is_admin());

-- admins : chacun peut seulement voir sa propre ligne (pour savoir s'il est admin)
create policy "admins_read_self" on public.admins for select using (user_id = auth.uid());

-- bets : lecture publique, un pari par compte connecté tant que la chasse est ouverte
create policy "bets_read" on public.bets for select using (true);

create policy "bets_insert" on public.bets for insert
with check (
  auth.uid() is not null
  and user_id = auth.uid()
  and exists (
    select 1 from public.hunts h
    where h.id = hunt_id
      and h.status = 'open'
      and (h.closes_at is null or h.closes_at > now())
  )
);

-- pas de modification possible par les joueurs ; seul un admin peut supprimer un pari
create policy "bets_delete_admin" on public.bets for delete using (public.is_admin());

-- ---------- Option : cacher les paris jusqu'à la clôture --------------
-- Si tu ne veux pas que les gens copient les paris des autres, remplace
-- la policy "bets_read" par celle-ci :
--
--   drop policy "bets_read" on public.bets;
--   create policy "bets_read" on public.bets for select using (
--     user_id = auth.uid()
--     or public.is_admin()
--     or exists (select 1 from public.hunts h
--                where h.id = hunt_id and h.status <> 'open')
--   );

-- ---------- Devenir admin ---------------------------------------------
-- 1) Connecte-toi une première fois sur le site avec ton compte Twitch.
-- 2) Exécute ceci en remplaçant TON_PSEUDO_TWITCH (en minuscules) :
--
--   insert into public.admins (user_id)
--   select id from auth.users
--   where lower(coalesce(raw_user_meta_data->>'preferred_username',
--                        raw_user_meta_data->>'user_name',
--                        raw_user_meta_data->>'name')) = 'TON_PSEUDO_TWITCH';
--
-- Pour ajouter un autre admin plus tard, même requête avec son pseudo
-- (il doit s'être connecté au moins une fois).
