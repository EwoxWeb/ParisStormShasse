
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
const state = { user: null, isAdmin: false, hunts: [], huntId: null, bets: [], tab: 'switch', view: 'public', adminHuntId: null, counts: {}, manuals: [], twitchAccts: [], sel: { m: null, t: null }, adminPage: 'hunts' };

/* Liens directs : #sw ouvre l'onglet Switch, #ds ouvre l'onglet 3DS (#switch et #3ds marchent aussi) */
const HASH_TO_TAB = { sw: 'switch', switch: 'switch', ds: '3ds', '3ds': '3ds' };
const TAB_TO_HASH = { switch: 'sw', '3ds': 'ds' };
const tabFromHash = () => HASH_TO_TAB[location.hash.replace(/^#/, '').toLowerCase()] || null;
function takeSavedTab() {   // onglet mémorisé avant la connexion Twitch (la redirection fait perdre le #)
  try { const t = sessionStorage.getItem('tab'); sessionStorage.removeItem('tab'); return t === 'switch' || t === '3ds' ? t : null; }
  catch { return null; }
}
function onHash() { const t = tabFromHash(); if (t && t !== state.tab) { state.tab = t; render(); } }

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
  try { sessionStorage.setItem('tab', state.tab); } catch {}
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
  const row = { title: f.title.value.trim(), platform: f.platform.value };
  if (f.closes.value) row.closes_at = new Date(f.closes.value).toISOString();
  if (!row.title) return toast('Indique le Pokémon de la shasse.', 'err');
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

/* ---------- admin : paris manuels et fusion de joueurs ---------- */
const RPC_ERRORS = {
  PSEUDO_INVALIDE: 'Pseudo invalide (lettres, chiffres et _ ; 2 à 25 caractères).',
  NOMBRE_INVALIDE: 'Nombre invalide.', SHASSE_TERMINEE: 'Cette shasse est terminée.', SHASSE_INTROUVABLE: 'Shasse introuvable.',
  LIMITE_2_PARIS: 'Ce joueur a déjà 2 paris sur cette shasse.', PARI_DEJA_JOUE: 'Ce joueur a déjà parié ce nombre.',
  CONFLIT_TROP_DE_PARIS: 'Fusion impossible : le joueur aurait plus de 2 paris sur une même shasse.',
  CONFLIT_MEME_NOMBRE: 'Fusion impossible : le même nombre serait parié deux fois sur une shasse.',
  ADMIN_REQUIS: 'Action réservée aux admins.', COMPTE_TWITCH_INTROUVABLE: 'Compte Twitch introuvable.',
  JOUEUR_MANUEL_INTROUVABLE: 'Joueur manuel introuvable.'
};
const rpcError = e => { const m = e?.message || ''; const k = Object.keys(RPC_ERRORS).find(x => m.includes(x)); return k ? RPC_ERRORS[k] : 'Erreur : ' + m; };

async function loadPeople() {
  const [m, t] = await Promise.all([sb.from('manual_players').select('*').order('pseudo'), sb.rpc('admin_list_twitch_accounts')]);
  state.manuals = m.data || []; state.twitchAccts = t.data || [];
  if (m.error || t.error) toast('Chargement des joueurs impossible : ' + (m.error || t.error).message, 'err');
}
async function addManualBet(ev, huntId) {
  ev.preventDefault();
  const f = ev.target.elements;
  const { data, error } = await sb.rpc('admin_add_bet', { p_hunt: huntId, p_pseudo: f.pseudo.value.trim(), p_guess: parseInt(f.guess.value, 10) });
  if (error) return toast(rpcError(error), 'err');
  toast(data === 'compte' ? 'Pari rattaché au compte Twitch existant.' : 'Pari ajouté pour un joueur manuel.');
  ev.target.reset(); refresh();
}
async function mergePlayers() {
  const m = state.manuals.find(x => x.id === state.sel.m), t = state.twitchAccts.find(x => x.user_id === state.sel.t);
  if (!m || !t) return;
  if (!confirm('Fusionner « ' + m.pseudo + ' » avec le compte Twitch « ' + t.pseudo + ' » ? Ses paris manuels seront transférés sur ce compte. Action définitive.')) return;
  const { error } = await sb.rpc('admin_merge_manual_player', { p_manual: m.id, p_user: t.user_id });
  if (error) return toast(rpcError(error), 'err');
  state.sel = { m: null, t: null }; toast('Fusion effectuée.');
  await loadPeople(); refresh();
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

/* ----- classement : une ligne par joueur (ses 2 paris), points ----- */
const keyOf = b => b.user_id || ('m:' + b.manual_player_id);
function groupPlayers(bets, result) {
  const map = new Map();
  for (const b of bets) {
    const k = keyOf(b);
    if (!map.has(k)) map.set(k, { key: k, user_id: b.user_id, manual: !!b.manual_player_id, name: b.twitch_name, avatar: b.twitch_avatar, bets: [] });
    map.get(k).bets.push(b);
  }
  const list = [...map.values()];
  for (const p of list) {
    p.bets.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    p.first = new Date(p.bets[0].created_at);
    if (result != null) {
      p.best = [...p.bets].sort((a, b) => Math.abs(a.guess - result) - Math.abs(b.guess - result) || new Date(a.created_at) - new Date(b.created_at))[0];
      p.diff = Math.abs(p.best.guess - result);
    }
  }
  return result != null
    ? list.sort((a, b) => a.diff - b.diff || new Date(a.best.created_at) - new Date(b.best.created_at))
    : list.sort((a, b) => b.first - a.first);
}
/* barème : nombre pile = 5 pts, 1er = 3, 2e = 2, 3e = 1 */
const pointsFor = (p, rank) => p.diff === 0 ? 5 : ({ 1: 3, 2: 2, 3: 1 }[rank] || 0);

function playerRow(p, rank, result, maxDiff) {
  const done = result != null;
  const pct = done ? Math.max(4, 100 - (maxDiff ? (p.diff / maxDiff) * 96 : 0)) : 0;
  const pts = done ? pointsFor(p, rank) : 0;
  const rankCls = 'rank' + (done && rank <= 3 ? ' r' + rank : '');
  return h('div', { class: 'row' + (p.user_id && p.user_id === state.user?.id ? ' me-row' : '') },
    done && h('div', { class: 'bar', style: 'width:' + pct + '%' }),
    h('div', { class: 'rankcell' },
      h('div', { class: rankCls }, done ? rank : '•'),
      pts > 0 && h('div', { class: 'pts' }, '+' + pts + ' pts')),
    h('div', { class: 'who' },
      safeAvatar(p.avatar) && h('img', { src: safeAvatar(p.avatar), alt: '', loading: 'lazy', referrerpolicy: 'no-referrer' }),
      h('span', {}, p.name),
      state.isAdmin && p.manual && h('small', { class: 'tag' }, 'manuel')),
    h('div', { class: 'guesses' }, p.bets.map(b => h('span', { class: 'chip' + (done && b === p.best ? ' best' : '') },
      fmtNum(b.guess),
      state.isAdmin && h('button', { class: 'x', title: 'Supprimer ce pari', 'aria-label': 'Supprimer ce pari', onclick: () => deleteBet(b.id) }, '×')))),
    h('div', { class: 'diff' + (p.diff === 0 ? ' exact' : '') }, !done ? '' : p.diff === 0 ? 'Pile !' : '± ' + fmtNum(p.diff)));
}

function huntSection(cur) {
  const p = platOf(cur);
  const done = cur.result != null;
  const open = isOpen(cur);
  const bets = betsOfHunt(cur.id);
  const mine = bets.filter(b => b.user_id === state.user?.id).sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
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

  const players = groupPlayers(bets, done ? cur.result : null);
  const maxDiff = done && players.length ? players[players.length - 1].diff : 0;
  const sub = cur.closes_at && !done ? (open ? 'Fermeture des paris : ' : 'Paris fermés depuis le ') + fmtDate(cur.closes_at) : '';

  return h('section', { class: 'card plat', style: '--p:' + p.color },
    h('div', { class: 'plat-head' },
      h('h2', {}, cur.title),
      h('span', { class: 'badge ' + (done ? 'finished' : open ? 'open' : '') }, done ? 'Terminée' : open ? 'Paris ouverts' : 'Paris fermés')),
    sub && h('div', { class: 'sub', style: 'margin-bottom:10px' }, sub),
    top,
    done && h('h3', {}, 'Classement (' + players.length + ')'),
    done && (players.length
      ? h('div', { class: 'list' }, players.map((pl, i) => playerRow(pl, i + 1, cur.result, maxDiff)))
      : h('p', { class: 'empty' }, 'Aucun pari sur cette shasse.')),
    !done && h('div', { class: 'hint', style: 'margin-top:18px' }, 'Les paris des autres participants restent cachés jusqu’à la publication du résultat.'),
    done && players.length > 0 && h('div', { class: 'hint' }, 'Chaque joueur apparaît une seule fois : son pari le plus proche compte. À égalité d’écart, le plus ancien passe devant. Points : nombre pile = 5, 1er = 3, 2e = 2, 3e = 1.'));
}

function createForm() {
  return h('form', { onsubmit: createHunt },
    h('label', {}, 'Pokémon', h('input', { name: 'title', maxlength: 80, placeholder: 'Dracaufeu', required: true })),
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
              h('span', { class: 'hi-main' }, h('b', {}, x.title), h('small', {}, p.label)),
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
  const players = groupPlayers(bets, done ? cur.result : null);
  const maxDiff = done && players.length ? players[players.length - 1].diff : 0;
  const info = (k, v) => [h('dt', {}, k), h('dd', {}, v)];

  return h('div', {},
    h('button', { class: 'back', onclick: closeAdminHunt }, '← Toutes les shasses'),
    h('section', { class: 'card plat', style: '--p:' + p.color },
      h('div', { class: 'plat-head' }, h('h2', {}, cur.title), h('span', { class: 'badge ' + statusClass(cur) }, statusLabel(cur))),
      h('dl', { class: 'info' },
        info('Console', p.label),
        info('Créée le', fmtDate(cur.created_at)),
        info('Fermeture auto', cur.closes_at ? fmtDate(cur.closes_at) : 'Aucune'),
        info('Résultat', done ? fmtNum(cur.result) + ' rencontres' : 'Pas encore saisi'),
        info('Paris', bets.length + ' (' + players.length + ' joueurs)'))),
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
    !done && cur.status !== 'finished' && h('section', { class: 'card admin' },
      h('h2', {}, 'Ajouter un pari à la main'),
      h('form', { onsubmit: ev => addManualBet(ev, cur.id) },
        h('label', {}, 'Pseudo Twitch', h('input', { name: 'pseudo', maxlength: 25, placeholder: 'pseudo_twitch', required: true, autocomplete: 'off' })),
        h('label', {}, 'Nombre de rencontres', h('input', { name: 'guess', type: 'number', min: 1, step: 1, required: true })),
        h('button', { class: 'gold', type: 'submit' }, 'Ajouter le pari')),
      h('div', { class: 'hint' }, 'Si le pseudo correspond à un compte Twitch déjà connecté, le pari lui est rattaché. Sinon, un joueur manuel est créé (onglet « Joueurs ») et pourra être fusionné plus tard.')),
    h('section', { class: 'card' },
      h('h2', {}, (done ? 'Classement' : 'Joueurs') + ' (' + players.length + ')'),
      players.length
        ? h('div', { class: 'list' }, players.map((pl, i) => playerRow(pl, i + 1, done ? cur.result : null, maxDiff)))
        : h('p', { class: 'empty' }, 'Aucun pari sur cette shasse.')));
}

function adminPeople() {
  const pick = (kind, id) => { state.sel[kind] = state.sel[kind] === id ? null : id; render(); };
  const mSel = state.manuals.find(x => x.id === state.sel.m), tSel = state.twitchAccts.find(x => x.user_id === state.sel.t);
  const manualCount = id => state.bets.filter(b => b.manual_player_id === id).length;
  const twitchCount = id => state.bets.filter(b => b.user_id === id).length;
  return h('section', { class: 'card admin' },
    h('h2', {}, 'Fusionner un joueur manuel avec un compte Twitch'),
    h('p', { class: 'hint' }, 'Choisis un joueur ajouté à la main (à gauche) et le compte Twitch qui lui correspond (à droite), puis fusionne : ses paris sont transférés sur le compte.'),
    h('div', { class: 'merge' },
      h('div', {},
        h('h3', {}, 'Ajoutés à la main (' + state.manuals.length + ')'),
        h('div', { class: 'scroll' }, state.manuals.length
          ? state.manuals.map(x => h('button', { class: 'pick' + (state.sel.m === x.id ? ' on' : ''), onclick: () => pick('m', x.id) },
              h('span', {}, x.pseudo), h('small', {}, manualCount(x.id) + ' pari(s)')))
          : h('p', { class: 'empty' }, 'Aucun joueur ajouté à la main.'))),
      h('div', {},
        h('h3', {}, 'Comptes Twitch connectés (' + state.twitchAccts.length + ')'),
        h('div', { class: 'scroll' }, state.twitchAccts.length
          ? state.twitchAccts.map(x => h('button', { class: 'pick' + (state.sel.t === x.user_id ? ' on' : ''), onclick: () => pick('t', x.user_id) },
              h('span', { class: 'who' }, safeAvatar(x.avatar) && h('img', { src: safeAvatar(x.avatar), alt: '', referrerpolicy: 'no-referrer' }), x.pseudo),
              h('small', {}, twitchCount(x.user_id) + ' pari(s)')))
          : h('p', { class: 'empty' }, 'Aucun compte connecté pour le moment.')))),
    h('div', { class: 'actions' },
      h('button', { class: 'gold', disabled: !(mSel && tSel), onclick: mergePlayers },
        mSel && tSel ? 'Fusionner ' + mSel.pseudo + ' → ' + tSel.pseudo : 'Fusionner')));
}

function adminView() {
  const nav = h('div', { class: 'tabs' }, [['hunts', 'Shasses'], ['people', 'Joueurs']].map(([k, label]) =>
    h('button', { class: 'tab' + (state.adminPage === k ? ' on' : ''), style: '--p:var(--twitch)',
      onclick: async () => { state.adminPage = k; state.adminHuntId = null; if (k === 'people') await loadPeople(); render(); } }, h('b', {}, label))));
  const cur = state.adminHuntId ? state.hunts.find(x => x.id === state.adminHuntId) : null;
  return h('div', {}, nav, state.adminPage === 'people' ? adminPeople() : cur ? adminDetail(cur) : adminList());
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
      onclick: () => { state.tab = p.key; history.replaceState(null, '', '#' + TAB_TO_HASH[p.key]); render(); } },
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
  if (!window.supabase) {
    $app.replaceChildren(h('div', { class: 'card' }, h('h2', {}, 'Erreur de chargement'),
      h('p', { class: 'setup' }, 'La bibliothèque supabase-js est introuvable : le dossier lib/ n’a pas été publié sur GitHub.')));
    return;
  }
  sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { data } = await sb.auth.getSession();
  state.user = data.session?.user || null;
  state.tab = tabFromHash() || takeSavedTab() || state.tab;   // après getSession : le # de connexion est déjà traité
  window.addEventListener('hashchange', onHash);
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
