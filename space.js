// Magilu Finance · Espacios (TOMÁS / JP)
// ----------------------------------------------------------------------------
// Cada usuario tiene su espacio (sus datos). Además puede entrar en otros:
//   · rol 'completo'  → todo ese espacio (Tomás en el de JP)
//   · rol 'depositos' → solo Depósitos (JP en el de Tomás)
// El espacio elegido se manda al servidor en la cabecera x-mf-space y es el
// servidor (RLS, current_space()) quien decide qué se ve y qué se puede hacer.
// Aquí solo: selector arriba a la derecha, franja grande cuando NO estás en lo
// tuyo, y llevar a Depósitos si en ese espacio solo tienes Depósitos.
// En tu propio espacio no se manda cabecera: todo funciona como siempre.
// Se carga después del SDK de Supabase y ANTES de offline.js.
// ----------------------------------------------------------------------------
(function () {
  'use strict';
  var REF = 'bgrsjftxwuduvlglfpky';
  var AUTH_KEY = 'sb-' + REF + '-auth-token';

  function ls(k, v) {
    try {
      if (arguments.length === 1) return localStorage.getItem(k);
      if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v);
    } catch (e) { return null; }
    return null;
  }
  function storedSession() {
    try {
      var s = JSON.parse(ls(AUTH_KEY) || 'null');
      if (s && s.currentSession) s = s.currentSession;
      return (s && s.user) ? s : null;
    } catch (e) { return null; }
  }

  var session = storedSession();
  var uid = session ? session.user.id : null;
  var KEY_LIST = uid ? 'mf_spaces:' + uid : null;
  var KEY_SEL = uid ? 'mf_space:' + uid : null;

  function readList() {
    if (!KEY_LIST) return [];
    try { var l = JSON.parse(ls(KEY_LIST) || '[]'); return Array.isArray(l) ? l : []; } catch (e) { return []; }
  }
  var list = readList();
  function ownEntry() {
    return list.find(function (s) { return s.propio; }) || { id: uid, nombre: '', rol: 'propio', propio: true };
  }
  var sel = KEY_SEL ? ls(KEY_SEL) : null;
  var active = (sel && list.find(function (s) { return s.id === sel; })) || ownEntry();
  var foreign = !!(uid && active && !active.propio);

  window.MF_SPACE = uid ? { id: active.id, nombre: active.nombre, rol: active.rol, propio: !foreign, uid: uid } : null;
  // Usuario "del espacio": mismo usuario, pero su id es el del espacio activo
  window.mfSpaceUser = function (u) {
    if (!u || !window.MF_SPACE || u.id !== uid) return u;
    return Object.assign({}, u, { id: window.MF_SPACE.id, realId: u.id });
  };
  window.mfSpaceCan = function (what) {   // 'todo' | 'borrar'
    return !window.MF_SPACE || window.MF_SPACE.rol !== 'depositos';
  };

  var page = (location.pathname.split('/').pop() || 'index.html').toLowerCase();

  // En un espacio donde solo tienes Depósitos, cualquier otra pantalla lleva a Depósitos
  if (foreign && active.rol === 'depositos' && page !== 'depositos.html') {
    location.replace('./depositos.html');
    return;
  }

  // Cabecera x-mf-space en todas las peticiones (solo fuera de tu espacio)
  var api = null;
  if (window.supabase && typeof window.supabase.createClient === 'function') {
    var orig = window.supabase.createClient;
    window.supabase.createClient = function (url, key, opts) {
      api = { url: url, key: key };
      if (foreign) {
        opts = Object.assign({}, opts || {});
        opts.global = Object.assign({}, opts.global || {});
        opts.global.headers = Object.assign({}, opts.global.headers || {}, { 'x-mf-space': active.id });
      }
      var c = orig.call(this, url, key, opts);
      setTimeout(refresh, 0);
      return c;
    };
  }

  function choose(id) {
    var s = list.find(function (x) { return x.id === id; });
    if (!s) return;
    ls(KEY_SEL, s.propio ? null : s.id);
    if (s.rol === 'depositos') location.href = './depositos.html';
    else location.href = location.pathname;   // sin ?dep=… de otro espacio
  }

  // Lista de espacios del servidor (si no hay red, se usa la guardada)
  var refreshed = false;
  function refresh() {
    if (refreshed || !api || !uid || navigator.onLine === false) return;
    refreshed = true;
    var s = storedSession();
    if (!s || !s.access_token || s.user.id !== uid) return;
    fetch(api.url + '/rest/v1/rpc/mf_spaces', {
      method: 'POST',
      headers: { apikey: api.key, Authorization: 'Bearer ' + s.access_token, 'Content-Type': 'application/json' },
      body: '{}'
    }).then(function (r) { return r.ok ? r.json() : null; }).then(function (fresh) {
      if (!Array.isArray(fresh)) return;
      var before = JSON.stringify(list);
      list = fresh;
      ls(KEY_LIST, JSON.stringify(fresh));
      // Te han quitado el acceso al espacio en el que estabas: vuelta a lo tuyo
      if (foreign && !fresh.some(function (x) { return x.id === active.id && x.rol === active.rol; })) {
        ls(KEY_SEL, null);
        location.href = './index.html';
        return;
      }
      if (before !== JSON.stringify(fresh)) renderSelector();
    }).catch(function () { /* sin red: lo guardado */ });
  }

  // ------------------------------------------------------------ interfaz
  var css = ''
    + '.mf-space-sel{background:#0e1626;border:1px solid #3a4a6e;color:#e8eef7;border-radius:6px;height:32px;'
    + 'padding:0 8px;font:600 12px/1 "JetBrains Mono",monospace;letter-spacing:.06em;cursor:pointer;margin-right:6px}'
    + '.mf-space-sel.foreign{border-color:#f0b429;background:#f0b429;color:#1a1200}'
    + '.mf-band{position:sticky;top:0;z-index:60;display:flex;align-items:center;justify-content:center;gap:12px;'
    + 'flex-wrap:wrap;background:#f0b429;color:#1a1200;padding:calc(12px + env(safe-area-inset-top)) 16px 12px;'
    + 'font:800 17px/1.25 "Inter Tight",system-ui,sans-serif;letter-spacing:.04em;text-transform:uppercase;'
    + 'text-align:center;box-shadow:0 4px 18px rgba(0,0,0,.45);border-bottom:3px solid #1a1200}'
    + '.mf-band button{background:#1a1200;color:#f0b429;border:none;border-radius:6px;padding:7px 12px;'
    + 'font:700 12px/1 "Inter Tight",system-ui,sans-serif;letter-spacing:.03em;text-transform:none;cursor:pointer}'
    + 'html.mf-foreign .app-header{top:var(--mf-band-h,0px)!important;padding-top:10px!important}'
    + '@media (max-width:600px){.mf-band{font-size:15px;gap:8px}.mf-space-sel{height:30px;font-size:11px;padding:0 5px}}';

  function renderSelector() {
    if (!uid || list.length < 2) return;
    var slot = document.querySelector('[data-privacy-slot]') || document.querySelector('.header-inner');
    if (!slot) return;
    var old = document.getElementById('mfSpaceSel');
    if (old) old.remove();
    var s = document.createElement('select');
    s.id = 'mfSpaceSel';
    s.className = 'mf-space-sel' + (foreign ? ' foreign' : '');
    s.title = 'Cambiar de usuario';
    s.setAttribute('aria-label', 'Usuario');
    list.forEach(function (x) {
      var o = document.createElement('option');
      o.value = x.id;
      o.textContent = x.nombre + (x.rol === 'depositos' ? ' · depósitos' : '');
      if (x.id === active.id) o.selected = true;
      s.appendChild(o);
    });
    s.addEventListener('change', function () { choose(s.value); });
    slot.insertBefore(s, slot.firstChild);
  }

  function renderBand() {
    if (!foreign) return;
    document.documentElement.classList.add('mf-foreign');
    var b = document.createElement('div');
    b.className = 'mf-band';
    b.setAttribute('role', 'status');
    var t = document.createElement('span');
    t.textContent = active.rol === 'depositos'
      ? 'Estás en los depósitos de ' + active.nombre
      : 'Estás en el espacio de ' + active.nombre;
    var back = document.createElement('button');
    back.type = 'button';
    back.textContent = '← Volver a lo mío';
    back.addEventListener('click', function () { choose(ownEntry().id); });
    b.appendChild(t);
    b.appendChild(back);
    document.body.insertBefore(b, document.body.firstChild);
    var fit = function () { document.documentElement.style.setProperty('--mf-band-h', b.offsetHeight + 'px'); };
    fit();
    // La altura cambia al cargar la fuente o al girar el móvil: la cabecera fija va justo debajo
    if (window.ResizeObserver) new ResizeObserver(fit).observe(b); else window.addEventListener('resize', fit);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fit);
    document.title = '[' + active.nombre + '] ' + document.title;
  }

  function ui() {
    var st = document.createElement('style');
    st.textContent = css;
    document.head.appendChild(st);
    renderBand();
    renderSelector();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ui, { once: true }); else ui();
})();
