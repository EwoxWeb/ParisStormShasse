-- =====================================================================
-- Migration v17 : édition des sections et de tous les textes publics
-- À lancer UNE SEULE FOIS (après la v16).
-- =====================================================================

begin;

update public.site_content
set rules = jsonb_build_object(
  'title', 'Fonctionnement des paris chez NovaStorm',
  'sections', jsonb_build_array(
    jsonb_build_object(
      'title', '',
      'paragraphs', jsonb_build_array(jsonb_build_object(
        'text', coalesce(rules->>'intro', ''),
        'highlight', false,
        'lead', ''
      )),
      'items', '[]'::jsonb,
      'listStyle', 'none'
    ),
    jsonb_build_object(
      'title', 'Comment parier ?',
      'paragraphs', jsonb_build_array(
        jsonb_build_object('text', coalesce(rules->>'commands', ''), 'highlight', false, 'lead', ''),
        jsonb_build_object('text', coalesce(rules->>'form', ''), 'highlight', false, 'lead', ''),
        jsonb_build_object('text', coalesce(rules->>'foxier', ''), 'highlight', false, 'lead', 'Nouveauté : ')
      ),
      'items', '[]'::jsonb,
      'listStyle', 'none'
    ),
    jsonb_build_object(
      'title', 'Mais… à quoi ça sert ?',
      'paragraphs', jsonb_build_array(jsonb_build_object(
        'text', coalesce(rules->>'purpose', ''),
        'highlight', false,
        'lead', ''
      )),
      'items', '[]'::jsonb,
      'listStyle', 'none'
    )
  ),
  'linkPrefix', 'Ou clique ',
  'linkText', 'ici',
  'linkSuffix', '.',
  'rewardsUrl', coalesce(rules->>'rewardsUrl', 'https://ewoxweb.github.io/ParisStormShasse/#classement'),
  'footer', coalesce(rules->>'closing', '')
),
leaderboard_content = jsonb_build_object(
  'title', coalesce(leaderboard_content->>'title', 'Classement des paris — Saison 2'),
  'sections', jsonb_build_array(
    jsonb_build_object(
      'title', '',
      'paragraphs', coalesce(
        (select jsonb_agg(paragraph || jsonb_build_object('lead', coalesce(paragraph->>'lead', '')))
         from jsonb_array_elements(
           case when jsonb_typeof(leaderboard_content->'paragraphs') = 'array'
             then leaderboard_content->'paragraphs' else '[]'::jsonb end
         ) as paragraphs(paragraph)),
        '[]'::jsonb
      ),
      'items', '[]'::jsonb,
      'listStyle', 'none'
    ),
    jsonb_build_object(
      'title', 'Récompenses pour les 6 premiers',
      'paragraphs', '[]'::jsonb,
      'items', case when jsonb_typeof(leaderboard_content->'rewards') = 'array'
        then leaderboard_content->'rewards' else '[]'::jsonb end,
      'listStyle', 'ordered'
    ),
    jsonb_build_object(
      'title', 'Attribution des points',
      'paragraphs', '[]'::jsonb,
      'items', jsonb_build_array(
        'Nombre pile = 5 points',
        '1er = 3 points',
        '2ème = 2 points',
        '3ème = 1 point'
      ),
      'listStyle', 'unordered'
    ),
    jsonb_build_object(
      'title', '',
      'paragraphs', jsonb_build_array(jsonb_build_object(
        'text', 'Utilise la commande Ctrl+F puis tape ton pseudo pour te trouver dans la liste !',
        'highlight', false,
        'lead', ''
      )),
      'items', '[]'::jsonb,
      'listStyle', 'none'
    )
  ),
  'scoreTitle', 'Classement',
  'winnerTemplate', 'Seuil des 35 points atteint par {name} ({points} points) !',
  'scoreLabelTemplate', '{points} pts',
  'emptyScoreText', '—',
  'scoreHint', 'Les scores de départ sont conservés ; les points des nouvelles shasses terminées sont ajoutés automatiquement.'
)
where id = 1;

commit;
