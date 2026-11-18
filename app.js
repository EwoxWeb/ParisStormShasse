
/* Anti-clickjacking : le site refuse de s'afficher dans une iframe */
if (window.top !== window.self) { document.documentElement.textContent = ''; throw new Error('framed'); }

const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.APP_CONFIG || {};
const configured = !!SUPABASE_URL && !!SUPABASE_ANON_KEY
  && !SUPABASE_URL.includes('VOTRE-PROJET') && !SUPABASE_ANON_KEY.includes('VOTRE_CLE');

const $app = document.getElementById('app');
const $auth = document.getElementById('auth');
const $toast = document.getElementById('toast');

/* Les deux consoles de la double shasse */
const PLATFORMS = [
  { key: 'switch', label: 'Switch', col: 'result_switch', color: '#e4002b' },
  { key: '3ds',    label: '3DS',    col: 'result_3ds',    color: '#1a8fd6' },
];

let sb = null;
const state = { user: null, isAdmin: false, hunts: [], huntId: null, bets: [], tab: 'switch', view: 'public', adminHuntId: null, counts: {} };

/* ---------- petits utilitaires (aucun innerHTML avec des données utilisateur) ---------- */
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'value') el.value = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
let toastTimer;
function toast(msg, type = 'ok') {
  $toast.textContent = msg; $toast.className = type; $toast.style.display = 'block';
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $toast.style.display = 'none'; }, 4500);
}
const fmtDate = d => new Date(d).toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
const fmtNum = n => Number(n).toLocaleString('fr-FR');
const twitchName = u => u?.user_metadata?.preferred_username || u?.user_metadata?.user_name || u?.user_metadata?.name || 'Anonyme';
/* n'accepte que les avatars hébergés par Twitch (https uniquement) */
const safeAvatar = u => (typeof u === 'string' && /^https:\/\/static-cdn\.jtvnw\.net\//.test(u)) ? u : '';
const avatar = u => safeAvatar(u?.user_metadata?.avatar_url || u?.user_metadata?.picture);

const hunt = () => state.hunts.find(x => x.id === state.huntId) || null;
const platOf = x => PLATFORMS.find(p => p.key === x.platform) || PLATFORMS[0];
const isOpen = x => x && x.status === 'open' && x.result == null && (!x.closes_at || new Date(x.closes_at) > new Date());
const MAX_BETS = 2;
const betsOfHunt = id => state.bets.filter(b => b.hunt_id === id);

/* ---------- données ---------- */
async function loadHunts() {
  const { data, error } = await sb.from('hunts').select('*').order('created_at', { ascending: false });
  if (error) return toast('Impossible de charger les shasses : ' + error.message, 'err');
  state.hunts = data;
  if (!state.huntId || !data.some(x => x.id === state.huntId)) {
    state.huntId = (data.find(x => x.status !== 'finished') || data[0] || {}).id || null;
  }
}
async function loadBets() {
  const { data, error } = await sb.from('bets').select('*').order('created_at', { ascending: true });
  if (error) return toast('Impossible de charger les paris : ' + error.message, 'err');
  state.bets = data;
}
async function loadAdmin() {
  state.isAdmin = false;
  if (!state.user) return;
  const { data } = await sb.from('admins').select('user_id').eq('user_id', state.user.id).maybeSingle();
  state.isAdmin = !!data;
}
async function loadCounts() {
  const { data } = await sb.from('bets').select('hunt_id');
  state.counts = {};
  (data || []).forEach(r => { state.counts[r.hunt_id] = (state.counts[r.hunt_id] || 0) + 1; });
}
async function refresh() { await loadHunts(); await loadBets(); if (state.view === 'admin') await loadCounts(); render(); }

/* navigation du panel admin */
async function toggleAdmin() {
  state.view = state.view === 'admin' ? 'public' : 'admin';
  state.adminHuntId = null;
  if (state.view === 'admin') await loadCounts();
  render();
}
async function openAdminHunt(id) { state.adminHuntId = id; state.huntId = id; await loadBets(); render(); }
async function closeAdminHunt() { state.adminHuntId = null; await loadCounts(); render(); }

/* ---------- actions ---------- */
function login() {
  sb.auth.signInWithOAuth({ provider: 'twitch', options: { redirectTo: location.origin + location.pathname } });
}
async function logout() { await sb.auth.signOut(); }

async function placeBet(ev, huntId) {
  ev.preventDefault();
  const guess = parseInt(ev.target.elements.guess.value, 10);
  if (!Number.isInteger(guess) || guess < 1) return toast('Entre un nombre de rencontres supérieur à 0.', 'err');
  const { error } = await sb.from('bets').insert({ hunt_id: huntId, guess });
  if (error) {
    const m = error.message || '';
    if (m.includes('LIMITE_2_PARIS')) toast('Tu as déjà placé tes ' + MAX_BETS + ' paris sur cette shasse.', 'err');
    else if (m.includes('PARI_DEJA_JOUE')) toast('Tu as déjà parié ce nombre. Choisis-en un autre.', 'err');
    else if (m.includes('COMPTE_TWITCH_REQUIS')) toast('Connecte-toi avec un compte Twitch pour parier.', 'err');
    else if (error.code === '42501') toast('Les paris sont fermés pour cette shasse.', 'err');
    else toast('Erreur : ' + m, 'err');
    return refresh();
  }
  toast('Pari enregistré. Bonne chance !');
  refresh();
}

async function createHunt(ev) {
  ev.preventDefault();
  const f = ev.target.elements;
  const row = { title: f.title.value.trim(), pokemon: f.pokemon.value.trim() || null, platform: f.platform.value };
  if (f.closes.value) row.closes_at = new Date(f.closes.value).toISOString();
  if (!row.title) return toast('Donne un titre à la shasse.', 'err');
  const { data, error } = await sb.from('hunts').insert(row).select().single();
  if (error) return toast('Création impossible : ' + error.message, 'err');
  state.huntId = data.id; toast('Shasse créée.'); ev.target.reset(); refresh();
}
async function setStatus(status) {
  const { error } = await sb.from('hunts').update({ status }).eq('id', state.huntId);
  if (error) return toast(error.message, 'err');
  toast(status === 'open' ? 'Paris rouverts.' : 'Paris fermés.'); refresh();
}
async function finishHunt(ev) {
  ev.preventDefault();
  const n = parseInt(ev.target.elements.result.value, 10);
  if (!Number.isInteger(n) || n < 1) return toast('Entre le nombre final de rencontres.', 'err');
  if (!confirm('Valider ' + fmtNum(n) + ' rencontres comme résultat final ? Les paris seront clos.')) return;
  const { error } = await sb.from('hunts').update({ result: n, status: 'finished' }).eq('id', state.huntId);
  if (error) return toast(error.message, 'err');
  toast('Résultat enregistré, le classement est publié.'); refresh();
}
async function reopenResult() {
  if (!confirm('Annuler le résultat et repasser la shasse en « paris fermés » ?')) return;
  const { error } = await sb.from('hunts').update({ result: null, status: 'closed' }).eq('id', state.huntId);
  if (error) return toast(error.message, 'err');
  refresh();
}
async function deleteHunt() {
  if (!confirm('Supprimer cette shasse et tous ses paris ? Action définitive.')) return;
  const { error } = await sb.from('hunts').delete().eq('id', state.huntId);
  if (error) return toast(error.message, 'err');
  state.huntId = null; state.adminHuntId = null; toast('Shasse supprimée.'); refresh();
}
async function deleteBet(id) {
  if (!confirm('Supprimer ce pari ?')) return;
  const { error } = await sb.from('bets').delete().eq('id', id);
  if (error) return toast(error.message, 'err');
  refresh();
}

/* ---------- rendu ---------- */
function renderAuth() {
  $auth.replaceChildren();
  if (state.user) {
    $auth.append(h('div', { class: 'me' },
      avatar(state.user) && h('img', { src: avatar(state.user), alt: '' }),
      h('span', {}, twitchName(state.user)),
      state.isAdmin && h('button', { class: 'gold', onclick: toggleAdmin }, state.view === 'admin' ? 'Retour au site' : 'Admin'),
      h('button', { onclick: logout }, 'Se déconnecter')));
  } else if (configured) {
    $auth.append(h('button', { class: 'primary', onclick: login }, 'Se connecter avec Twitch'));
  }
}

function betRow(b, rank, result, maxDiff) {
  const diff = result == null ? null : Math.abs(b.guess - result);
  const pct = diff == null ? 0 : Math.max(4, 100 - (maxDiff ? (diff / maxDiff) * 96 : 0));
  const rankCls = 'rank' + (rank <= 3 && result != null ? ' r' + rank : '');
  return h('div', { class: 'row' + (b.user_id === state.user?.id ? ' me-row' : '') },
    result != null && h('div', { class: 'bar', style: 'width:' + pct + '%' }),
    h('div', { class: rankCls }, result != null ? rank : '•'),
    h('div', { class: 'who' }, safeAvatar(b.twitch_avatar) && h('img', { src: safeAvatar(b.twitch_avatar), alt: '', loading: 'lazy', referrerpolicy: 'no-referrer' }), h('span', {}, b.twitch_name)),
    h('div', { class: 'guess' }, fmtNum(b.guess)),
    h('div', { class: 'diff' + (diff === 0 ? ' exact' : '') },
      diff == null ? '' : diff === 0 ? 'Pile !' : '± ' + fmtNum(diff)),
    state.isAdmin && h('button', { class: 'danger', title: 'Supprimer ce pari', onclick: () => deleteBet(b.id) }, 'Suppr.'));
}

function huntSection(cur) {
  const p = platOf(cur);
  const done = cur.result != null;
  const open = isOpen(cur);
  const bets = betsOfHunt(cur.id);
  const mine = bets.filter(b => b.user_id === state.user?.id);
  const left = MAX_BETS - mine.length;

  const mineBlock = mine.length > 0 && h('div', { class: 'tickets' },
    mine.map((b, i) => h('div', { class: 'ticket' },
      h('div', { class: 't-label' }, 'Pari n°' + (i + 1)),
      h('div', { class: 't-num' }, fmtNum(b.guess)),
      h('div', { class: 't-date' }, 'Verrouillé – ' + fmtDate(b.created_at)))),
    h('div', { class: 'hint' }, 'Tes paris sont enregistrés : impossible de les modifier ou de les supprimer.'));

  let top;
  if (done) {
    top = h('div', { class: 'result' },
      h('div', { class: 'lbl' }, 'Le shiny est tombé à'),
      h('div', { class: 'big' }, fmtNum(cur.result)),
      h('div', { class: 'lbl' }, 'rencontres sur ' + p.label));
  } else if (!open) {
    top = h('div', {}, mineBlock, h('p', { class: 'empty' }, 'Les paris sont fermés pour cette shasse.'));
  } else if (!state.user) {
    top = h('div', {},
      h('p', {}, 'Connecte-toi avec ton compte Twitch pour parier. Ton pseudo est récupéré automatiquement.'),
      h('button', { class: 'primary', onclick: login }, 'Se connecter avec Twitch'));
  } else if (left > 0) {
    top = h('div', {}, mineBlock,
      h('form', { class: 'counter', onsubmit: ev => placeBet(ev, cur.id) },
        h('input', { name: 'guess', type: 'number', inputmode: 'numeric', min: 1, step: 1, placeholder: '0000', required: true, 'aria-label': 'Nombre de rencontres' }),
        h('button', { class: 'gold', type: 'submit' }, 'Valider mon pari')),
      h('div', { class: 'hint' }, 'Il te reste ' + left + (left > 1 ? ' paris' : ' pari') + ' sur ' + MAX_BETS + '. Un pari enregistré ne peut ni être modifié ni supprimé.'));
  } else {
    top = h('div', {}, mineBlock, h('div', { class: 'hint' }, 'Tu as placé tes ' + MAX_BETS + ' paris sur cette shasse.'));
  }

  const sorted = done
    ? [...bets].sort((a, b) => Math.abs(a.guess - cur.result) - Math.abs(b.guess - cur.result) || new Date(a.created_at) - new Date(b.created_at))
    : [...bets].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  const maxDiff = done && sorted.length ? Math.abs(sorted[sorted.length - 1].guess - cur.result) : 0;

  return h('section', { class: 'card plat', style: '--p:' + p.color },
    h('div', { class: 'plat-head' },
      h('h2', {}, cur.title),
      h('span', { class: 'badge ' + (done ? 'finished' : open ? 'open' : '') }, done ? 'Terminée' : open ? 'Paris ouverts' : 'Paris fermés')),
    [cur.pokemon, cur.closes_at && !done ? (open ? 'Fermeture des paris : ' : 'Paris fermés depuis le ') + fmtDate(cur.closes_at) : null].filter(Boolean).length > 0
      && h('div', { class: 'sub', style: 'margin-bottom:10px' },
           [cur.pokemon, cur.closes_at && !done ? (open ? 'Fermeture des paris : ' : 'Paris fermés depuis le ') + fmtDate(cur.closes_at) : null].filter(Boolean).join(' – ')),
    top,
    done && h('h3', {}, 'Classement (' + bets.length + ')'),
    done && (sorted.length
      ? h('div', { class: 'list' }, sorted.map((b, i) => betRow(b, i + 1, cur.result, maxDiff)))
      : h('p', { class: 'empty' }, 'Aucun pari sur cette shasse.')),
    !done && h('div', { class: 'hint', style: 'margin-top:18px' }, 'Les paris des autres participants restent cachés jusqu’à la publication du résultat.'),
    done && sorted.length > 1 && h('div', { class: 'hint' }, 'Chaque pari est classé séparément. À égalité d’écart, le plus ancien passe devant.'));
}

function createForm() {
  return h('form', { onsubmit: createHunt },
    h('label', {}, 'Titre', h('input', { name: 'title', maxlength: 80, placeholder: 'Shasse Dracaufeu', required: true })),
    h('label', {}, 'Pokémon', h('input', { name: 'pokemon', maxlength: 40, placeholder: 'Dracaufeu' })),
    h('label', {}, 'Fermeture auto (option)', h('input', { name: 'closes', type: 'datetime-local' })),
    h('div', { class: 'consoles' },
      PLATFORMS.map((p, i) => h('label', { class: 'chk' }, h('input', { type: 'radio', name: 'platform', value: p.key, checked: i === 0 }), p.label))),
    h('button', { class: 'gold', type: 'submit' }, 'Créer la shasse'));
}
const statusLabel = x => x.status === 'finished' ? 'Terminée' : isOpen(x) ? 'Ouverte' : 'Fermée';
const statusClass = x => x.status === 'finished' ? 'finished' : isOpen(x) ? 'open' : '';

function adminList() {
  return h('div', {},
    h('section', { class: 'card admin' },
      h('h2', {}, 'Shasses'),
      state.hunts.length
        ? h('div', { class: 'list' }, state.hunts.map(x => {
            const p = platOf(x);
            return h('button', { class: 'hunt-item', style: '--p:' + p.color, onclick: () => openAdminHunt(x.id) },
              h('span', { class: 'dot' }),
              h('span', { class: 'hi-main' }, h('b', {}, x.title), h('small', {}, [p.label, x.pokemon].filter(Boolean).join(' – '))),
              h('span', { class: 'hi-meta' }, (state.counts[x.id] || 0) + ' paris' + (x.result != null ? ' – résultat ' + fmtNum(x.result) : '')),
              h('span', { class: 'badge ' + statusClass(x) }, statusLabel(x)));
          }))
        : h('p', { class: 'empty' }, 'Aucune shasse pour le moment.')),
    h('section', { class: 'card admin' }, h('h2', {}, 'Nouvelle shasse'), createForm()));
}

function adminDetail(cur) {
  const p = platOf(cur);
  const bets = betsOfHunt(cur.id);
  const done = cur.result != null;
  const sorted = done
    ? [...bets].sort((a, b) => Math.abs(a.guess - cur.result) - Math.abs(b.guess - cur.result) || new Date(a.created_at) - new Date(b.created_at))
    : [...bets].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  const maxDiff = done && sorted.length ? Math.abs(sorted[sorted.length - 1].guess - cur.result) : 0;
  const info = (k, v) => [h('dt', {}, k), h('dd', {}, v)];

  return h('div', {},
    h('button', { class: 'back', onclick: closeAdminHunt }, '← Toutes les shasses'),
    h('section', { class: 'card plat', style: '--p:' + p.color },
      h('div', { class: 'plat-head' }, h('h2', {}, cur.title), h('span', { class: 'badge ' + statusClass(cur) }, statusLabel(cur))),
      h('dl', { class: 'info' },
        info('Console', p.label), info('Pokémon', cur.pokemon || '—'),
        info('Créée le', fmtDate(cur.created_at)),
        info('Fermeture auto', cur.closes_at ? fmtDate(cur.closes_at) : 'Aucune'),
        info('Résultat', done ? fmtNum(cur.result) + ' rencontres' : 'Pas encore saisi'),
        info('Paris', String(bets.length)))),
    h('section', { class: 'card admin' },
      h('h2', {}, 'Actions'),
      cur.status !== 'finished' && h('div', { class: 'actions' },
        cur.status === 'open'
          ? h('button', { onclick: () => setStatus('closed') }, 'Fermer les paris')
          : h('button', { onclick: () => setStatus('open') }, 'Rouvrir les paris')),
      done
        ? h('div', { class: 'res-line' }, h('span', {}, 'Résultat : '), h('strong', {}, fmtNum(cur.result)),
            h('button', { onclick: reopenResult }, 'Annuler le résultat'))
        : h('form', { onsubmit: finishHunt },
            h('label', {}, 'Nombre final de rencontres', h('input', { name: 'result', type: 'number', min: 1, step: 1, required: true })),
            h('button', { class: 'gold', type: 'submit' }, 'Valider le résultat')),
      h('div', { class: 'actions' }, h('button', { class: 'danger', onclick: deleteHunt }, 'Supprimer cette shasse'))),
    h('section', { class: 'card' },
      h('h2', {}, (done ? 'Classement' : 'Paris') + ' (' + sorted.length + ')'),
      sorted.length
        ? h('div', { class: 'list' }, sorted.map((b, i) => betRow(b, i + 1, done ? cur.result : null, maxDiff)))
        : h('p', { class: 'empty' }, 'Aucun pari sur cette shasse.')));
}

function adminView() {
  const cur = state.adminHuntId ? state.hunts.find(x => x.id === state.adminHuntId) : null;
  return cur ? adminDetail(cur) : adminList();
}

function render() {
  renderAuth();
  if (!configured) {
    $app.replaceChildren(h('div', { class: 'card' },
      h('h2', {}, 'Configuration manquante'),
      h('p', { class: 'setup' }, 'Renseigne SUPABASE_URL et SUPABASE_ANON_KEY en haut du script de index.html (voir le README).')));
    return;
  }
  if (state.view === 'admin' && state.isAdmin) { $app.replaceChildren(adminView()); return; }
  const list = state.hunts.filter(x => x.platform === state.tab)
    .sort((a, b) => (a.status === 'finished') - (b.status === 'finished'));
  const tabP = PLATFORMS.find(p => p.key === state.tab);
  const nodes = [h('div', { class: 'tabs plats', role: 'tablist' }, PLATFORMS.map(p => {
    const n = state.hunts.filter(x => x.platform === p.key && isOpen(x)).length;
    return h('button', { class: 'tab' + (p.key === state.tab ? ' on' : ''), role: 'tab',
      'aria-selected': p.key === state.tab ? 'true' : 'false', style: '--p:' + p.color,
      onclick: () => { state.tab = p.key; render(); } },
      h('span', { class: 'dot' }), h('b', {}, p.label),
      n > 0 && h('span', { class: 'badge open' }, n + (n > 1 ? ' ouvertes' : ' ouverte')));
  }))];
  if (!list.length) {
    nodes.push(h('div', { class: 'card' }, h('h2', {}, 'Aucune shasse ' + tabP.label + ' pour le moment'),
      h('p', { class: 'empty' }, state.isAdmin ? 'Crée-en une depuis le bouton Admin.' : 'Reviens bientôt, une shasse va démarrer.')));
  }
  list.forEach(x => nodes.push(huntSection(x)));
  $app.replaceChildren(...nodes);
}

/* ---------- démarrage ---------- */
async function start() {
  if (!configured) return render();
  sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { data } = await sb.auth.getSession();
  state.user = data.session?.user || null;
  await loadAdmin();
  await refresh();
  sb.auth.onAuthStateChange(async (_evt, session) => {
    const uid = session?.user?.id || null;
    if (uid === (state.user?.id || null)) return;
    state.user = session?.user || null;
    await loadAdmin(); await refresh();
  });
  // rafraîchissement doux toutes les 20 s quand l'onglet est visible
  setInterval(() => {
    if (document.hidden || document.activeElement?.tagName === 'INPUT') return;
    refresh();
  }, 20000);
}
start();
