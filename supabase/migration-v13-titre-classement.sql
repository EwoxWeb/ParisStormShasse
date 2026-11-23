-- =====================================================================
-- Migration v13 : titre du classement éditable
-- À lancer UNE SEULE FOIS (après la v12).
-- =====================================================================

begin;

update public.site_content
set leaderboard_content = jsonb_set(
  leaderboard_content,
  '{title}',
  to_jsonb('Classement des paris — Saison 2'::text),
  true
)
where id = 1
  and not (leaderboard_content ? 'title');

commit;
