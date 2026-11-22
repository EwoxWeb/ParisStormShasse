-- =====================================================================
-- Migration v10 : édition des règles et des scores de départ depuis l'admin
-- À lancer UNE SEULE FOIS (après la v9).
-- =====================================================================

begin;

create table public.site_content (
  id          smallint primary key default 1 check (id = 1),
  rules       jsonb not null check (jsonb_typeof(rules) = 'object'),
  leaderboard jsonb not null check (jsonb_typeof(leaderboard) = 'array')
);

insert into public.site_content (id, rules, leaderboard) values (
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
  ]'::jsonb
);

alter table public.site_content enable row level security;
revoke all on table public.site_content from public, anon, authenticated;
grant select on table public.site_content to anon, authenticated;
grant update on table public.site_content to authenticated;

create policy "site_content_read" on public.site_content for select to anon, authenticated
  using (true);
create policy "site_content_update_admin" on public.site_content for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

commit;
