-- =====================================================================
-- Migration v12 : paragraphes et récompenses du classement éditables
-- À lancer UNE SEULE FOIS (après la v11).
-- =====================================================================

begin;

alter table public.site_content
  add column leaderboard_content jsonb not null default '{
    "title": "Classement des paris — Saison 2",
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
  check (jsonb_typeof(leaderboard_content) = 'object');

commit;
