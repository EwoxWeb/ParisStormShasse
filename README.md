# Paris Shiny ✨

Site de pronostics pour une chasse shiny Pokémon : les viewers se connectent avec Twitch, parient un nombre de rencontres, et les admins saisissent le résultat final. Le classement va du pari le plus proche au plus éloigné.

**Hébergement 100 % gratuit** : GitHub Pages (site) + Supabase (base de données et connexion Twitch).

## Contenu

| Fichier | Rôle |
|---|---|
| `index.html`, `style.css`, `app.js` | Le site (aucun script ni style inline, pour une CSP stricte) |
| `config.js` | Configuration du projet Supabase : URL et clé publique |
| `lib/` | supabase-js 2.45.4 hébergé localement (aucun CDN externe) |
| `SECURITY.md` | Checklist sécurité et tests d'attaque |
| `supabase/migration-v6-securite.sql` | Durcissement sécurité (à lancer après la v5) |
| `supabase/migration-v7-joueurs-manuels.sql` | Paris ajoutés à la main + fusion avec les comptes Twitch (après la v6) |
| `supabase/migration-v8-images.sql` | Image ou GIF du Pokémon sur chaque shasse (après la v7) |
| `supabase/migration-v9-classement-saison.sql` | Date des résultats pour le classement automatique de la Saison 2 (après la v8) |
| `supabase/migration-v10-contenu-admin.sql` | Édition admin des règles et des scores de départ (après la v9) |
| `supabase/migration-v11-lien-classement.sql` | Le lien « ici » des règles ouvre le classement (après la v10) |
| `supabase/migration-v12-contenu-classement.sql` | Édition des paragraphes et récompenses du classement (après la v11) |
| `supabase/schema.sql` | Tables et règles de sécurité (installation neuve, déjà en double chasse) |
| `supabase/migration-v3-choix-consoles.sql` | Étape intermédiaire (à lancer avant la v4 si pas déjà fait) |
| `supabase/migration-v4-une-console-deux-paris.sql` | Une chasse = une console, 2 paris max par chasse |
| `supabase/migration-v5-paris-caches.sql` | Les joueurs ne voient que leurs propres paris jusqu'au résultat |
| `supabase/migration-v2-switch-3ds.sql` | À lancer une fois si ta base existait avant la double chasse |
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

1. Dans `config.js`, remplace `SUPABASE_URL` et `SUPABASE_ANON_KEY` (clé publique uniquement). Si tu changes de projet Supabase, mets aussi à jour l'URL dans la balise CSP de `index.html`.
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
select i.user_id from auth.identities i
where i.provider = 'twitch'
  and lower(coalesce(i.identity_data->>'preferred_username', i.identity_data->>'user_name', i.identity_data->>'name')) = 'ton_pseudo_twitch';
```

3. Recharge le site : le **panneau admin** apparaît en bas de page.

### 5. Éviter la mise en pause de Supabase

Dans ton dépôt GitHub : **Settings > Secrets and variables > Actions**, ajoute :

- `SUPABASE_URL` : l'URL de ton projet
- `SUPABASE_ANON_KEY` : la clé anon

Le workflow `keepalive.yml` interroge la base chaque jour. Tu peux le tester à la main dans l'onglet **Actions > Supabase keep-alive > Run workflow**.

## Switch, 3DS et 2 paris par chasse

- Une chasse = **une seule console** : tu la choisis (Switch ou 3DS) à la création. Pour une double chasse, tu crées deux chasses, une par console. Les viewers passent de l'une à l'autre avec les onglets en haut de page.
- Chaque viewer peut placer **2 paris par chasse** (deux nombres différents).
- Un pari enregistré ne peut **ni être modifié ni être supprimé** par son auteur. Seul un admin peut supprimer un pari (modération).
- Le résultat se saisit par chasse : le classement s'affiche et les paris se ferment.

**Si ta base existait déjà**, lance les migrations manquantes dans l'ordre. Pour activer le classement automatique et l'édition admin, lance les migrations v9, v10, v11, puis `supabase/migration-v12-contenu-classement.sql`, une seule fois chacune. Les résultats existants ne sont pas recomptés ; toute shasse terminée à partir de maintenant, y compris une shasse déjà en cours, sera prise en compte.

## Liens directs (commandes du chat)

- `https://ewoxweb.github.io/ParisStormShasse/#sw` ouvre directement l'onglet **Switch** (commande `!sw`)
- `https://ewoxweb.github.io/ParisStormShasse/#ds` ouvre directement l'onglet **3DS** (commande `!ds`)

Le lien est à mettre dans la réponse des commandes de ton bot Twitch. Après la connexion Twitch, le viewer revient sur l'onglet d'où il est parti.

## Utilisation

**Admin** (panneau en bas de page)
1. Créer une chasse (titre, Pokémon, fermeture automatique optionnelle).
2. Fermer les paris quand tu veux, ou laisser la date de fermeture le faire.
3. Quand le shiny tombe, saisir le nombre final de rencontres. Le classement s'affiche pour tout le monde.
4. Dans **Admin > Contenu**, modifier les textes des règles ou gérer les pseudos et scores de départ. Les points gagnés sur les shasses restent calculés automatiquement.

**Viewers**
1. Connexion Twitch, saisie du nombre pour chaque console, un pari par compte et par console, non modifiable.

## Sécurité

- Le pseudo est lu côté serveur dans le compte Twitch connecté (trigger SQL). Il ne peut pas être falsifié depuis le navigateur.
- 2 paris maximum par compte et par chasse, jamais deux fois le même nombre (vérifié en base).
- Les paris ne sont acceptés que si la chasse est ouverte et avant l'heure de fermeture : c'est la base qui vérifie, pas le site.
- Seuls les admins peuvent créer ou modifier une chasse, saisir le résultat et supprimer un pari.
- **Paris cachés** : chaque joueur ne voit que ses propres paris, les admins voient tout. Les paris de tout le monde ne deviennent visibles qu'une fois le résultat publié (pour le classement). C'est la base de données qui l'impose (`migration-v5-paris-caches.sql`), pas seulement le site.

## Règles de classement

- Le classement de la Saison 2 commence avec les scores fournis : Finity (10), Dylho (9), Pokemaz (5) et Ewox (2). Les points de chaque nouvelle shasse terminée sont ajoutés automatiquement.
- Barème : nombre pile = 5 points ; 1er = 3 points ; 2ème = 2 points ; 3ème = 1 point.
- Écart = valeur absolue entre le pari et le résultat.
- À écart égal, le pari **le plus ancien** passe devant.

## Dépannage

- **La connexion Twitch échoue** : vérifie l'URL de redirection côté Twitch et les *Redirect URLs* côté Supabase. Le compte Twitch doit avoir un e-mail vérifié.
- **« Configuration manquante »** : `SUPABASE_URL` / `SUPABASE_ANON_KEY` n'ont pas été remplacés dans `index.html`.
- **Le site ne répond plus après une semaine d'inactivité** : projet en pause. Clique sur *Restore* dans le dashboard Supabase et vérifie que le workflow keep-alive tourne.
- **Pas de panneau admin** : relance la requête SQL de l'étape 4 après t'être connecté au moins une fois.
