-- =====================================================================
-- Migration v11 : le lien « ici » des règles ouvre le classement global
-- À lancer UNE SEULE FOIS (après la v10).
-- =====================================================================

begin;

update public.site_content
set rules = jsonb_set(
  rules,
  '{rewardsUrl}',
  to_jsonb('https://ewoxweb.github.io/ParisStormShasse/#classement'::text),
  true
)
where id = 1;

commit;
