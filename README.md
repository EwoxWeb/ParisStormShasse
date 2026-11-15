# Paris Shiny ✨

Site de pronostics pour une chasse shiny Pokémon : les viewers se connectent avec Twitch, parient un nombre de rencontres, et les admins saisissent le résultat final. Le classement va du pari le plus proche au plus éloigné.

**Hébergement 100 % gratuit** : GitHub Pages (site) + Supabase (base de données et connexion Twitch).

## Contenu

| Fichier | Rôle |
|---|---|
| `index.html` | Tout le site (HTML, CSS, JS) |
| `supabase/schema.sql` | Tables et règles de sécurité à coller dans Supabase |
| `.github/workflows/keepalive.yml` | Ping quotidien pour que Supabase ne mette pas le projet en pause |

## Mise en place

### 1. Créer le projet Supabase

1. Crée un compte sur [supabase.com](https://supabase.com) puis un nouveau projet (offre gratuite).
2. Ouvre **SQL Editor > New query**, colle tout `supabase/schema.sql` et clique sur **Run**.
3. Dans **Project Settings > API**, note l'**URL du projet** et la clé **anon public**.

### 2. Activer la connexion Twitch

1. Va sur la [console développeur Twitch](https://dev.twitch.tv/console) et clique sur **Register Your Application**.
2. **OAuth Redirect URLs** : `https://<ton-projet>.supabase.co/auth/v1/callback`
3. Catégorie : *Website Integration*, type de client : *Confidential*.
4. Copie le **Client ID** et génère un **Client Secret**.
5. Dans Supabase : **Authentication > Providers > Twitch**, active-le et colle l'ID et le secret.

### 3. Mettre le site en ligne sur GitHub Pages

1. Dans `index.html`, remplace `SUPABASE_URL` et `SUPABASE_ANON_KEY` (haut du script).
   La clé anon est publique par conception : la sécurité vient des règles RLS du `schema.sql`.
2. Crée un dépôt GitHub, pousse les fichiers (y compris le dossier `.github`).
3. **Settings > Pages** : source = *Deploy from a branch*, branche `main`, dossier `/ (root)`.
4. Ton site sera sur `https://<ton-pseudo>.github.io/<ton-depot>/`.
5. Dans Supabase : **Authentication > URL Configuration**
   - **Site URL** : l'adresse GitHub Pages ci-dessus
   - **Redirect URLs** : la même adresse

### 4. Te donner les droits admin

1. Ouvre ton site et connecte-toi avec ton compte Twitch.
2. Dans le SQL Editor, lance (en remplaçant par ton pseudo Twitch en minuscules) :

```sql
insert into public.admins (user_id)
select id from auth.users
where lower(coalesce(raw_user_meta_data->>'preferred_username',
                     raw_user_meta_data->>'user_name',
                     raw_user_meta_data->>'name')) = 'ton_pseudo_twitch';
```

3. Recharge le site : le **panneau admin** apparaît en bas de page.

### 5. Éviter la mise en pause de Supabase

Dans ton dépôt GitHub : **Settings > Secrets and variables > Actions**, ajoute :

- `SUPABASE_URL` : l'URL de ton projet
- `SUPABASE_ANON_KEY` : la clé anon

Le workflow `keepalive.yml` interroge la base chaque jour. Tu peux le tester à la main dans l'onglet **Actions > Supabase keep-alive > Run workflow**.

## Utilisation

**Admin** (panneau en bas de page)
1. Créer une chasse (titre, Pokémon, fermeture automatique optionnelle).
2. Fermer les paris quand tu veux, ou laisser la date de fermeture le faire.
3. Quand le shiny tombe, saisir le nombre final de rencontres. Le classement s'affiche pour tout le monde.

**Viewers**
1. Connexion Twitch, saisie du nombre, un seul pari par compte, non modifiable.

## Sécurité

- Le pseudo est lu côté serveur dans le compte Twitch connecté (trigger SQL). Il ne peut pas être falsifié depuis le navigateur.
- Un seul pari par compte et par chasse (contrainte unique en base).
- Les paris ne sont acceptés que si la chasse est ouverte et avant l'heure de fermeture : c'est la base qui vérifie, pas le site.
- Seuls les admins peuvent créer ou modifier une chasse, saisir le résultat et supprimer un pari.
- Les paris sont visibles par tous en direct. Pour les cacher jusqu'à la clôture (contre le copier-coller), un bloc de remplacement est fourni en commentaire dans `schema.sql`.

## Règles de classement

- Écart = valeur absolue entre le pari et le résultat.
- À écart égal, le pari **le plus ancien** passe devant.

## Dépannage

- **La connexion Twitch échoue** : vérifie l'URL de redirection côté Twitch et les *Redirect URLs* côté Supabase. Le compte Twitch doit avoir un e-mail vérifié.
- **« Configuration manquante »** : `SUPABASE_URL` / `SUPABASE_ANON_KEY` n'ont pas été remplacés dans `index.html`.
- **Le site ne répond plus après une semaine d'inactivité** : projet en pause. Clique sur *Restore* dans le dashboard Supabase et vérifie que le workflow keep-alive tourne.
- **Pas de panneau admin** : relance la requête SQL de l'étape 4 après t'être connecté au moins une fois.
