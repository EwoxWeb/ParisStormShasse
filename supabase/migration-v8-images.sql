-- =====================================================================
--  Migration v8 : image / GIF du Pokémon sur chaque shasse
--  À lancer UNE SEULE FOIS (après la v7). Tout est dans une transaction.
--
--  - colonne hunts.image_path (nom de fichier généré, jamais une URL libre)
--  - bucket public « pokemon » : 2 Mo max, PNG / JPG / GIF / WebP uniquement (pas de SVG)
--  - seuls les admins peuvent envoyer ou supprimer des images
-- =====================================================================

begin;

alter table public.hunts add column image_path text
  check (image_path is null or image_path ~ '^[0-9a-f-]{36}\.(png|jpg|jpeg|gif|webp)$');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pokemon', 'pokemon', true, 2097152, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

-- lecture publique via l'URL publique du bucket ; ces règles ne concernent que les admins
create policy "pokemon_admin_select" on storage.objects for select to authenticated
  using (bucket_id = 'pokemon' and (select public.is_admin()));

create policy "pokemon_admin_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'pokemon' and (select public.is_admin())
              and name ~ '^[0-9a-f-]{36}\.(png|jpg|jpeg|gif|webp)$');

create policy "pokemon_admin_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'pokemon' and (select public.is_admin()));

commit;
