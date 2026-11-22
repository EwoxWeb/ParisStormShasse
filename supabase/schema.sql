-- =====================================================================
--  Paris Shiny — schéma complet (INSTALLATION NEUVE uniquement)
--  Une chasse = une console (Switch ou 3DS), 2 paris max par compte et par chasse.
--  Si ta base existe déjà, utilise les fichiers migration-*.sql à la place.
--  Installation neuve : lance ce fichier, PUIS migration-v6-securite.sql, PUIS migration-v7-joueurs-manuels.sql.
-- =====================================================================

create table public.hunts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 80),
  pokemon     text check (char_length(pokemon) <= 40),
  platform    text not null check (platform in ('switch', '3ds')),
  status      text not null default 'open' check (status in ('open', 'closed', 'finished')),
  closes_at   timestamptz,
  result      integer check (result > 0),
  result_at   timestamptz,
  created_at  timestamptz not null default now(),
  check (status <> 'finished' or result is not null)
);

create or replace function public.set_hunt_result_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'finished' and new.result is not null then
    if tg_op = 'INSERT' then
      new.result_at := now();
    elsif old.status <> 'finished' or old.result is distinct from new.result then
      new.result_at := now();
    else
      new.result_at := old.result_at;
    end if;
  else
    new.result_at := null;
  end if;
  return new;
end;
$$;

create trigger hunts_set_result_at before insert or update on public.hunts
  for each row execute function public.set_hunt_result_at();

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

create table public.site_content (
  id          smallint primary key default 1 check (id = 1),
  rules       jsonb not null check (jsonb_typeof(rules) = 'object'),
  leaderboard jsonb not null check (jsonb_typeof(leaderboard) = 'array'),
  leaderboard_content jsonb not null check (jsonb_typeof(leaderboard_content) = 'object')
);

insert into public.site_content (id, rules, leaderboard, leaderboard_content) values (
  1,
  '{
    "intro": "Je shasse presque toujours avec 2 consoles différentes (Switch à gauche et DS/3DS à droite). Tu peux donc parier 2 chiffres pour chacune de mes deux shasses et ce n’importe quand.",
    "commands": "Pour parier, il te suffit d’écrire “!sw” pour la shasse en cours sur Switch ou bien “!ds” pour celle sur 3DS/DS.",
    "form": "Le bot va alors te répondre en te donnant un lien. Clique dessus : tu vas atterrir sur un formulaire dans lequel tu devras entrer ton pseudo Twitch, ainsi que les deux chiffres sur lesquels tu paries. Tu peux mettre n’importe quels chiffres mais choisis bien ! Tu ne pourras plus les modifier après. Clique sur “Valider mon pari” et voilà ! Ton pari est enregistré !",
    "foxier": "Il m’arrive parfois de shasser avec un ami, Foxier. Tu pourras également parier sur ses shasses avec la commande “!fx”.",
    "purpose": "Bon déjà… pour le fun ! Et puis tu peux aussi gagner des récompenses qui en valent la peine ! Pour les voir, écris “!top” dans le chat.",
    "rewardsUrl": "https://ewoxweb.github.io/ParisStormShasse/#classement",
    "closing": "Les résultats de chaque pari seront toujours affichés en live. Si tu as des questions, le chat du live est fait pour ça !"
  }'::jsonb,
  '[
    {"name": "Finity", "points": 10},
    {"name": "Dylho", "points": 9},
    {"name": "Pokemaz", "points": 5},
    {"name": "Ewox", "points": 2}
  ]'::jsonb,
  '{
    "paragraphs": [
      {"text": "Voici le classement des paris, soyez le premier à atteindre 35 points pour mettre fin à la Saison 2 !", "highlight": false},
      {"text": "NOUVEAU : Désormais il m’arrivera de shasser avec un ami (Foxier), vous pouvez également parier sur ses shasses.", "highlight": true}
    ],
    "rewards": [
      "Un grade VIP à vie sur la chaîne.",
      "Un sub offert (1 mois).",
      "Gagne ta place dans le prochain Battle Royal (avec Foxier, moi et quelqu’un tiré au sort).",
      "Choisis un jeu/fan game Pokémon que je ferai en stream (seul ou avec Foxier).",
      "Une carte cadeau Nintendo de 10 €.",
      "Impose-moi un défi pour une prochaine shasse (dans la limite du raisonnable)."
    ]
  }'::jsonb
);

alter table public.site_content enable row level security;
revoke all on table public.site_content from public, anon, authenticated;
grant select on table public.site_content to anon, authenticated;
grant update on table public.site_content to authenticated;
create policy "site_content_read" on public.site_content for select to anon, authenticated
  using (true);
create policy "site_content_update_admin" on public.site_content for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

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
