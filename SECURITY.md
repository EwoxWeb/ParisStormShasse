# Sécurité — Paris Shasse

## Ce qui est protégé, et comment

| Menace | Protection |
|---|---|
| Parier sous le pseudo de quelqu'un d'autre | Le pseudo est lu côté serveur dans `auth.identities` (fourni par Twitch, non modifiable par l'utilisateur). Le client ne peut même pas envoyer ce champ. |
| Modifier son pseudo via `auth.updateUser` | Sans effet : `user_metadata` n'est plus jamais utilisé pour le pseudo des paris. |
| Antidater un pari pour gagner une égalité | `created_at` est imposé par le serveur ; le client ne peut insérer que `hunt_id` et `guess`. |
| Parier plus de 2 fois, deux fois le même nombre | Contraintes uniques + trigger, vérifiés en base (impossible à contourner depuis le navigateur). |
| Parier après la clôture ou après le résultat | Règle RLS : shasse ouverte, sans résultat, avant `closes_at`. |
| Modifier ou supprimer son pari | Aucun droit UPDATE / DELETE pour les joueurs. |
| Lire les paris des autres | RLS : chacun voit les siens ; tout est visible seulement une fois le résultat publié. |
| Se faire passer pour admin | Table `admins` modifiable uniquement depuis le SQL Editor ; l'interface admin n'est qu'un affichage, la vraie barrière est le RLS. |
| Comptes bidon (email, anonyme) | Seuls les comptes avec une identité Twitch peuvent parier (`COMPTE_TWITCH_REQUIS`). |
| Injection de script (XSS) | Aucun `innerHTML`, aucun script inline, CSP stricte, avatars limités au CDN Twitch. |
| Script CDN piégé (supply chain) | supabase-js est hébergé dans `lib/` : plus aucun script externe. |
| Clickjacking | Le site refuse de s'afficher dans une iframe. |
| Actions admin douteuses | Journal `audit_log` (qui, quand, quoi), lisible par les admins seulement. |

## À régler dans les tableaux de bord (je ne peux pas le faire à ta place)

### Supabase
- **Authentication > Sign In / Providers** : **Twitch activé, tout le reste désactivé** (Email, Phone, Anonymous). C'est le point le plus important : sinon n'importe qui peut créer des comptes sans Twitch.
- **Authentication > URL Configuration** : Site URL et Redirect URLs = **uniquement** l'adresse exacte de ton GitHub Pages, sans `*`.
- **Project Settings > API Keys** : seule la clé *publishable* sert dans le site. La *secret key* ne doit apparaître nulle part (ni code, ni GitHub, ni capture d'écran). Si elle a fuité : la régénérer.
- **Database > Advisors > Security Advisor** : lance-le et vérifie qu'il n'y a aucune alerte rouge.
- Active la **double authentification** sur ton compte Supabase.
- Plan gratuit : pas de sauvegardes automatiques. Exporte `hunts` et `bets` en CSV (Table Editor) de temps en temps.

### GitHub
- **Double authentification** sur le compte qui possède le dépôt.
- Ne commit jamais de clé secrète. Les secrets du workflow (`SUPABASE_URL`, clé publishable) vont dans **Settings > Secrets and variables > Actions**.
- **Settings > Pages** : coche **Enforce HTTPS**.

### Twitch
- Double authentification sur le compte développeur. Si le *Client Secret* a été exposé : le régénérer sur dev.twitch.tv et le mettre à jour dans Supabase.

## Vérifications après la migration v6

Dans le SQL Editor (lecture seule) :

```sql
-- 1) RLS actif partout (tout doit afficher true)
select tablename, rowsecurity from pg_tables where schemaname = 'public';

-- 2) liste des admins (doit contenir uniquement les personnes voulues)
select a.user_id, i.identity_data->>'preferred_username' as pseudo
from public.admins a left join auth.identities i on i.user_id = a.user_id and i.provider = 'twitch';

-- 3) paris dont le pseudo ne correspond pas à l'identité Twitch (doit être vide)
select b.id, b.twitch_name from public.bets b
join auth.identities i on i.user_id = b.user_id and i.provider = 'twitch'
where b.twitch_name is distinct from coalesce(i.identity_data->>'preferred_username',
      i.identity_data->>'user_name', i.identity_data->>'name');

-- 4) paris faits par des comptes sans identité Twitch (à vérifier, devrait être vide)
select b.id, b.twitch_name from public.bets b
where not exists (select 1 from auth.identities i where i.user_id = b.user_id and i.provider = 'twitch');

-- 5) journal des actions admin
select at, actor, action, table_name from public.audit_log order by at desc limit 50;
```

## Tests d'attaque à faire toi-même

Connecte-toi avec un compte **non admin**, ouvre la console du navigateur (F12) et lance :

```js
// doit échouer (« permission denied ») : le client n'a pas le droit d'écrire ces colonnes
await sb.from('bets').insert({ hunt_id: 'ID_D_UNE_SHASSE_OUVERTE', guess: 5, twitch_name: 'Pirate', created_at: '2000-01-01' })

// doit échouer : un joueur ne peut ni modifier ni supprimer
await sb.from('bets').update({ guess: 1 }).neq('guess', 0)
await sb.from('bets').delete().neq('guess', 0)

// doit échouer : un non-admin ne peut pas toucher aux shasses
await sb.from('hunts').update({ status: 'finished' }).neq('title', '')

// doit rester sans effet sur ton pseudo affiché : change ton pseudo côté métadonnées, puis place un pari normal
await sb.auth.updateUser({ data: { preferred_username: 'Pirate' } })
```

Les requêtes `update` / `delete` peuvent renvoyer « succès » avec 0 ligne modifiée : c'est normal, le RLS les filtre. Vérifie ensuite dans la table que rien n'a changé.

## Limites connues (honnêteté)

- **Une personne avec plusieurs comptes Twitch** peut placer plus de 2 paris. Se prémunir complètement demande une vérification de l'ancienneté des comptes côté serveur (Edge Function appelant l'API Twitch). Dis-moi si tu veux cette étape.
- **Un compte admin piraté = un admin piraté** : active la double authentification sur le compte Twitch des admins.
- Le plan gratuit a des quotas (requêtes, bande passante) : un afflux massif de trafic peut saturer le projet.
- Un identifiant interne (UUID) de chaque parieur est lisible une fois le résultat publié. Ce n'est pas un secret et ça ne permet aucune action.
