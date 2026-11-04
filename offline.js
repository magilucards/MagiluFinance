// Magilu Finance · Modo sin cobertura
// ----------------------------------------------------------------------------
// Envuelve el cliente de Supabase de cada página:
//  · CON conexión todo va al servidor como siempre. Además, lo que se escribe
//    se copia en el iPhone y, cada cierto tiempo, se descarga una copia de las
//    tablas que usa Depósitos (IndexedDB).
//  · SIN conexión (o si la red no responde) las lecturas salen de esa copia y,
//    en Depósitos, lo que se guarda queda en una cola en el iPhone y se sube
//    solo, en orden, al volver la cobertura.
//  · Lo que necesita internet por fuerza (Holded, firmas, emails, cobrar en
//    Tesorería) avisa de que no hay conexión.
// Las filas nuevas llevan su id desde el móvil: si una subida se repite, el
// servidor la reconoce como ya hecha y no se duplica nada.
// ----------------------------------------------------------------------------
(function () {
  'use strict';
  if (!window.supabase || typeof window.supabase.createClient !== 'function') return;

  var REF = 'bgrsjftxwuduvlglfpky';
  var AUTH_KEY = 'sb-' + REF + '-auth-token';
  var IDB_NAME = 'magilu-offline';
  var IDB_VER = 1;
  var html = document.documentElement;
  var WRITES_ON = html.getAttribute('data-offline-writes') === 'on';     // solo Depósitos
  var MIRROR_REFRESH_ON = html.getAttribute('data-offline-mirror') === 'on';
  var REFRESH_EVERY_MS = 15 * 60 * 1000;   // copia completa como mucho cada 15 min
  var OFFLINE_LATCH_MS = 30 * 1000;         // tras un fallo de red, 30 s sin reintentar
  var SESSION_WAIT_MS = 4000;               // la sesión no puede bloquear la app más de 4 s

  // Tablas que se copian en el iPhone (y columnas de orden estable para paginar).
  // debts / fixed_expenses / editable_data: el Plan financiero se puede consultar sin cobertura.
  var MIRROR = {
    deposits: 'id', deposit_lines: 'id', clients: 'id', products: 'id',
    client_locations: 'id', deposit_signatures: 'id', pending_collections: 'id', settings: 'user_id',
    debts: 'id', fixed_expenses: 'id', editable_data: 'id'
  };
  var VIEWS = { v_deposit_totals: true };
  // Tablas que Depósitos puede escribir sin conexión
  var WRITE_TABLES = { deposits: 1, deposit_lines: 1, pending_collections: 1, settings: 1 };
  // Funciones del servidor que se pueden dejar en cola (no cambian nada si se repiten)
  var QUEUE_RPC = { recalc_daily_record: 1 };

  // ---------------------------------------------------------------- utilidades
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16);
    });
  }
  function clone(o) { return o == null ? o : JSON.parse(JSON.stringify(o)); }
  function nowIso() { return new Date().toISOString(); }
  function mkErr(message, code, status) { return { message: message, code: code || 'OFFLINE', details: null, hint: null, status: status || 0 }; }
  var NET_RE = /failed to fetch|load failed|networkerror|network request failed|fetch failed|aborterror|the operation was aborted|internet|timed? ?out|err_internet|err_network/i;
  function isNetErr(r) {
    if (!r) return false;
    var e = r.error;
    if (!e) return false;
    if (r.status === 0 && !e.code) return true;
    return NET_RE.test(String(e.message || '')) || NET_RE.test(String(e.name || ''));
  }
  function netResult(msg) {
    return { data: null, error: mkErr(msg || 'Sin conexión: esta acción necesita internet.'), count: null, status: 0, statusText: 'offline' };
  }

  // ------------------------------------------------------- estado de la red
  var latchUntil = 0;
  function isOffline() { return navigator.onLine === false || Date.now() < latchUntil; }
  function markOffline() { latchUntil = Date.now() + OFFLINE_LATCH_MS; emitStatus(); }
  function markOnline() { if (latchUntil) { latchUntil = 0; emitStatus(); } }

  // -------------------------------------------------------------- IndexedDB
  var dbp = null;
  function idb() {
    if (dbp) return dbp;
    dbp = new Promise(function (resolve, reject) {
      if (!window.indexedDB) { reject(new Error('Sin IndexedDB')); return; }
      var r = indexedDB.open(IDB_NAME, IDB_VER);
      r.onupgradeneeded = function () {
        var d = r.result;
        if (!d.objectStoreNames.contains('mirror')) d.createObjectStore('mirror', { keyPath: 'name' });
        if (!d.objectStoreNames.contains('outbox')) d.createObjectStore('outbox', { keyPath: 'seq', autoIncrement: true });
        if (!d.objectStoreNames.contains('failed')) d.createObjectStore('failed', { keyPath: 'seq' });
      };
      r.onsuccess = function () { resolve(r.result); };
      r.onerror = function () { reject(r.error); };
    });
    try { if (navigator.storage && navigator.storage.persist) navigator.storage.persist(); } catch (e) { /* opcional */ }
    return dbp;
  }
  function req(store, mode, fn) {
    return idb().then(function (d) {
      return new Promise(function (resolve, reject) {
        var t = d.transaction(store, mode);
        var r = fn(t.objectStore(store));
        t.oncomplete = function () { resolve(r && r.result); };
        t.onerror = function () { reject(t.error); };
        t.onabort = function () { reject(t.error); };
      });
    });
  }
  function idbAll(store) { return req(store, 'readonly', function (s) { return s.getAll(); }); }
  function idbPut(store, v) { return req(store, 'readwrite', function (s) { return s.put(v); }); }
  function idbAdd(store, v) { return req(store, 'readwrite', function (s) { return s.add(v); }); }
  function idbDel(store, k) { return req(store, 'readwrite', function (s) { return s.delete(k); }); }

  // ------------------------------------------------- copia de las tablas (espejo)
  var M = { tables: {}, at: 0 };          // en memoria
  var outboxN = 0, failedN = 0, syncing = false;
  var ready = idbAll('mirror').then(function (recs) {
    (recs || []).forEach(function (r) { if (r.name === '__meta') M.at = r.at || 0; else M.tables[r.name] = r.rows || []; });
    return Promise.all([idbAll('outbox'), idbAll('failed')]);
  }).then(function (res) {
    outboxN = (res[0] || []).length; failedN = (res[1] || []).length;
  }).catch(function (e) { console.warn('[offline] sin copia local', e); });

  function mirrorHasData() { return !!(M.tables.deposits && M.tables.clients); }
  function T(name) { if (!M.tables[name]) M.tables[name] = []; return M.tables[name]; }
  var dirty = {}, saveTimer = null;
  function markDirty(name) {
    dirty[name] = true;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flushMirror, 150);
  }
  function flushMirror() {
    clearTimeout(saveTimer);
    var names = Object.keys(dirty); dirty = {};
    return Promise.all(names.map(function (n) { return idbPut('mirror', { name: n, rows: M.tables[n] || [] }); }))
      .catch(function (e) { console.warn('[offline] no se pudo guardar la copia', e); });
  }

  // ------------------------------------------------ consultas al estilo PostgREST
  function cmp(a, b) {
    if (typeof a === 'number' || typeof b === 'number') {
      var na = Number(a), nb = Number(b);
      if (!isNaN(na) && !isNaN(nb)) return na < nb ? -1 : na > nb ? 1 : 0;
    }
    if (typeof a === 'boolean' || typeof b === 'boolean') { a = String(a); b = String(b); }
    a = String(a); b = String(b);
    return a < b ? -1 : a > b ? 1 : 0;
  }
  function eqv(a, b) {
    if (a == null || b == null) return false;
    if (typeof a === 'boolean' || typeof b === 'boolean') return String(a) === String(b);
    if (typeof a === 'number' || typeof b === 'number') return Number(a) === Number(b);
    return String(a) === String(b);
  }
  function isv(a, b) {
    if (b === null || b === 'null') return a == null;
    if (b === true || b === 'true') return a === true;
    if (b === false || b === 'false') return a === false;
    return false;
  }
  function likev(a, pat, ci) {
    if (a == null) return false;
    var re = '^' + String(pat).replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*').replace(/_/g, '.') + '$';
    return new RegExp(re, ci ? 'i' : '').test(String(a));
  }
  function parseList(v) {
    if (Array.isArray(v)) return v;
    return String(v).replace(/^\(|\)$/g, '').split(',').map(function (s) { return s.trim().replace(/^"|"$/g, ''); });
  }
  function opFn(op, col, val) {
    var neg = false;
    if (op.indexOf('not.') === 0) { neg = true; op = op.slice(4); }
    var f;
    switch (op) {
      case 'eq': f = function (r) { return eqv(r[col], val); }; break;
      case 'neq': f = function (r) { return r[col] != null && !eqv(r[col], val); }; break;
      case 'gt': f = function (r) { return r[col] != null && cmp(r[col], val) > 0; }; break;
      case 'gte': f = function (r) { return r[col] != null && cmp(r[col], val) >= 0; }; break;
      case 'lt': f = function (r) { return r[col] != null && cmp(r[col], val) < 0; }; break;
      case 'lte': f = function (r) { return r[col] != null && cmp(r[col], val) <= 0; }; break;
      case 'is': f = function (r) { return isv(r[col], val); }; break;
      case 'in': var list = parseList(val); f = function (r) { return list.some(function (x) { return eqv(r[col], x); }); }; break;
      case 'like': f = function (r) { return likev(r[col], val, false); }; break;
      case 'ilike': f = function (r) { return likev(r[col], val, true); }; break;
      default: f = function () { return true; };
    }
    return neg ? function (r) { return !f(r); } : f;
  }
  function project(row, cols) {
    if (!cols || String(cols).trim() === '*') return clone(row);
    var out = {};
    String(cols).split(',').forEach(function (c) {
      c = c.trim(); if (!c) return;
      if (c === '*') { Object.assign(out, clone(row)); return; }
      var alias = c, src = c;
      var m = c.match(/^([a-zA-Z0-9_]+)\s*:\s*([a-zA-Z0-9_]+)$/);
      if (m) { alias = m[1]; src = m[2]; }
      src = src.replace(/::.*$/, '');
      out[alias] = row[src] === undefined ? null : clone(row[src]);
    });
    return out;
  }

  // Vista v_deposit_totals calculada en el iPhone (misma fórmula que el SQL)
  var RE_BY_VAT = { 21: 0.052, 10: 0.014, 4: 0.005 };
  function viewDepositTotals() {
    var cliRe = {};
    T('clients').forEach(function (c) { cliRe[c.id] = c.vat_regime === 'recargo_equivalencia'; });
    var linesBy = {};
    T('deposit_lines').forEach(function (l) { (linesBy[l.deposit_id] = linesBy[l.deposit_id] || []).push(l); });
    var pcBy = {};
    T('pending_collections').forEach(function (p) { if (p.deposit_id && !pcBy[p.deposit_id]) pcBy[p.deposit_id] = p; });
    return T('deposits').map(function (d) {
      var hasRe = d.client_has_re != null ? !!d.client_has_re : !!cliRe[d.client_id];
      var isB = (d.regime || 'A') === 'B';
      var t = { n: 0, ud: 0, us: 0, imp: 0, val: 0, base: 0, iva: 0, re: 0 };
      (linesBy[d.id] || []).forEach(function (l) {
        var qd = Number(l.qty_delivered) || 0, qr = l.qty_remaining == null ? null : (Number(l.qty_remaining) || 0);
        var price = Number(l.unit_price) || 0, vat = l.vat_rate == null ? 21 : Number(l.vat_rate);
        var sold = qd - (qr == null ? 0 : qr), b = sold * price;
        t.n++; t.ud += qd; t.val += qd * price; t.base += b;
        if (qr != null) { t.us += qd - qr; t.imp += (qd - qr) * price; }
        if (!isB) { t.iva += b * vat / 100; if (hasRe) t.re += b * (RE_BY_VAT[vat] || 0); }
      });
      var pc = pcBy[d.id];
      return Object.assign(clone(d), {
        dia: d.recount_date || d.invoice_date || d.delivery_date,
        has_re: hasRe, n_lines: t.n, units_delivered: t.ud, units_sold: t.us, importe_counted: t.imp,
        valor_deposito: t.val, base: t.base, iva: t.iva, re: t.re, total: t.base + t.iva + t.re,
        collection_status: pc ? pc.status : null
      });
    });
  }

  // Analiza la cadena de llamadas grabada (select/insert/update/delete + filtros)
  function analyze(chain) {
    var a = { op: 'select', cols: '*', count: null, head: false, payload: null, returning: false, onConflict: null,
              filters: [], orders: [], lim: null, rng: null, one: 0 };
    chain.forEach(function (c) {
      var m = c[0], x = c[1] || [];
      switch (m) {
        case 'select':
          if (a.op === 'select') { a.cols = x[0] || '*'; var o = x[1] || {}; a.count = o.count || null; a.head = !!o.head; }
          else { a.returning = true; a.cols = x[0] || '*'; }
          break;
        case 'insert': a.op = 'insert'; a.payload = x[0]; break;
        case 'upsert': a.op = 'upsert'; a.payload = x[0]; a.onConflict = x[1] && x[1].onConflict; break;
        case 'update': a.op = 'update'; a.payload = x[0]; break;
        case 'delete': a.op = 'delete'; break;
        case 'eq': case 'neq': case 'gt': case 'gte': case 'lt': case 'lte': case 'like': case 'ilike': case 'is':
          a.filters.push(opFn(m, x[0], x[1])); break;
        case 'in': a.filters.push(opFn('in', x[0], x[1])); break;
        case 'filter': a.filters.push(opFn(x[1], x[0], x[2])); break;
        case 'not': a.filters.push(opFn('not.' + x[1], x[0], x[2])); break;
        case 'match': Object.keys(x[0] || {}).forEach(function (k) { a.filters.push(opFn('eq', k, x[0][k])); }); break;
        case 'order': var oo = x[1] || {}; a.orders.push({ c: x[0], asc: oo.ascending !== false, nf: oo.nullsFirst }); break;
        case 'limit': a.lim = x[0]; break;
        case 'range': a.rng = [x[0], x[1]]; break;
        case 'single': a.one = 1; break;
        case 'maybeSingle': a.one = 2; break;
        default: break;
      }
    });
    return a;
  }

  // Ejecuta la consulta sobre la copia local (y la modifica si es una escritura)
  function execLocal(t, chain) {
    var a = analyze(chain), rows, out, count = null;
    var base = VIEWS[t] ? viewDepositTotals() : T(t);
    function matching() { return base.filter(function (r) { return a.filters.every(function (f) { return f(r); }); }); }

    if (a.op === 'select') {
      rows = matching().slice();
      if (a.orders.length) {
        rows.sort(function (x, y) {
          for (var i = 0; i < a.orders.length; i++) {
            var o = a.orders[i], p = x[o.c], q = y[o.c];
            if (p == null || q == null) {
              if (p == null && q == null) continue;
              var nf = o.nf != null ? o.nf : !o.asc;
              return (p == null) === nf ? -1 : 1;
            }
            var c = cmp(p, q); if (c) return o.asc ? c : -c;
          }
          return 0;
        });
      }
      if (a.count) count = rows.length;
      if (a.rng) rows = rows.slice(a.rng[0], a.rng[1] + 1);
      if (a.lim != null) rows = rows.slice(0, a.lim);
      out = a.head ? null : rows.map(function (r) { return project(r, a.cols); });
    } else if (VIEWS[t]) {
      return { data: null, error: mkErr('No se puede escribir en una vista'), count: null, status: 400 };
    } else if (a.op === 'insert' || a.op === 'upsert') {
      var list = Array.isArray(a.payload) ? a.payload : [a.payload];
      var tab = T(t);
      // Un depósito solo puede tener un cobro (como en el servidor)
      if (t === 'pending_collections' && a.op === 'insert') {
        for (var i = 0; i < list.length; i++) {
          var dep = list[i] && list[i].deposit_id;
          if (dep && tab.some(function (r) { return r.deposit_id === dep && r.id !== list[i].id; })) {
            return { data: null, error: mkErr('Este depósito ya tiene un cobro registrado; se ha evitado un duplicado.', '23505', 409), count: null, status: 409 };
          }
        }
      }
      rows = list.map(function (v) {
        var row = clone(v);
        var key = MIRROR[t] || 'id';
        var ex = row[key] != null ? tab.find(function (r) { return eqv(r[key], row[key]); }) : null;
        if (ex) { Object.assign(ex, row); return ex; }
        if (row.id == null && key === 'id') row.id = uuid();
        if (row.created_at == null) row.created_at = nowIso();
        if (row.updated_at == null) row.updated_at = row.created_at;
        tab.push(row);
        return row;
      });
      markDirty(t);
      out = a.returning ? rows.map(function (r) { return project(r, a.cols); }) : null;
    } else if (a.op === 'update') {
      rows = matching();
      rows.forEach(function (r) { Object.assign(r, clone(a.payload)); });
      if (rows.length) markDirty(t);
      out = a.returning ? rows.map(function (r) { return project(r, a.cols); }) : null;
    } else if (a.op === 'delete') {
      rows = matching();
      var ids = rows.map(function (r) { return r.id; });
      M.tables[t] = T(t).filter(function (r) { return rows.indexOf(r) < 0; });
      markDirty(t);
      // Borrar un depósito borra sus líneas y firmas (como en el servidor)
      if (t === 'deposits' && ids.length) {
        ['deposit_lines', 'deposit_signatures'].forEach(function (n) {
          M.tables[n] = T(n).filter(function (r) { return ids.indexOf(r.deposit_id) < 0; }); markDirty(n);
        });
        T('pending_collections').forEach(function (p) { if (ids.indexOf(p.deposit_id) >= 0) { p.deposit_id = null; markDirty('pending_collections'); } });
      }
      out = a.returning ? rows.map(function (r) { return project(r, a.cols); }) : null;
    }

    if (a.one) {
      var arr = out || [];
      if (arr.length === 1) out = arr[0];
      else if (arr.length === 0 && a.one === 2) out = null;
      else return { data: null, error: mkErr('JSON object requested, multiple (or no) rows returned', 'PGRST116', 406), count: count, status: 406 };
    }
    return { data: out, error: null, count: count, status: 200, statusText: 'OK (copia local)' };
  }

  // Tras una escritura correcta en el servidor, se refleja en la copia local
  function applyToMirror(t, chain, res) {
    // Sin copia completa de la tabla no se crea una a medias (se rellenará en la próxima descarga)
    if (!MIRROR[t] || !M.tables[t]) return;
    try {
      var a = analyze(chain);
      if ((a.op === 'insert' || a.op === 'upsert') && res && res.data && a.returning && a.cols === '*') {
        var list = Array.isArray(res.data) ? res.data : [res.data];
        execLocal(t, [['upsert', [list]]]);
      } else {
        // Inserciones: los ids ya vienen del móvil, así que la copia queda igual que el servidor
        var c2 = chain.filter(function (c) { return c[0] !== 'select' && c[0] !== 'single' && c[0] !== 'maybeSingle'; });
        if (a.op === 'insert') c2 = [['upsert', [a.payload]]];
        execLocal(t, c2);
      }
    } catch (e) { console.warn('[offline] copia local no actualizada', e); }
  }

  // ---------------------------------------------------------------- el cliente
  var REAL = null;

  function replayReal(t, chain) {
    try {
      var q = REAL.from(t);
      chain.forEach(function (c) { q = q[c[0]].apply(q, c[1] || []); });
      return Promise.resolve(q).then(function (r) { return r; }, function (e) {
        return { data: null, error: mkErr((e && e.message) || String(e)), status: 0 };
      });
    } catch (e) {
      return Promise.resolve({ data: null, error: mkErr((e && e.message) || String(e), 'CLIENT'), status: 400 });
    }
  }

  // Las filas nuevas de Depósitos llevan su id desde el móvil (subida repetida = sin duplicados)
  function ensureIds(t, chain) {
    if (!WRITES_ON || !WRITE_TABLES[t] || MIRROR[t] !== 'id') return;
    chain.forEach(function (c) {
      if (c[0] !== 'insert') return;
      var p = c[1][0];
      var list = Array.isArray(p) ? p : [p];
      list.forEach(function (row) { if (row && row.id == null) row.id = uuid(); });
    });
  }

  function isWriteChain(chain) {
    return chain.some(function (c) { return c[0] === 'insert' || c[0] === 'upsert' || c[0] === 'update' || c[0] === 'delete'; });
  }

  function run(t, chain) {
    var write = isWriteChain(chain);
    var local = !!(MIRROR[t] || VIEWS[t]);
    var queueable = write && WRITES_ON && !!WRITE_TABLES[t];
    if (write) ensureIds(t, chain);

    // Sin conexión: se usa la copia del iPhone (hay que esperar a que esté cargada)
    function offlinePath() {
      return ready.then(function () {
        if (!write) {
          // Una tabla que aún no se ha copiado nunca no se da por vacía
          if (local && mirrorHasData() && (VIEWS[t] || M.tables[t])) return execLocal(t, chain);
          return netResult(local ? 'Sin conexión y sin copia en este dispositivo: abre la app una vez con cobertura.' : null);
        }
        if (queueable && mirrorHasData()) {
          var r = execLocal(t, chain);
          if (r.error) return r;
          // Se guarda en el iPhone antes de dar el cambio por hecho
          return flushMirror()
            .then(function () { return enqueue({ kind: 'from', t: t, chain: clone(chain), at: nowIso() }); })
            .then(function () { return r; });
        }
        return netResult();
      });
    }

    if (isOffline()) return offlinePath();
    // Con conexión: directo al servidor, como siempre
    return replayReal(t, chain).then(function (r) {
      if (isNetErr(r)) { markOffline(); return offlinePath(); }
      markOnline();
      if (write && !r.error) ready.then(function () { applyToMirror(t, chain, r); });
      return r;
    });
  }

  function Q(t) { this.t = t; this.chain = []; }
  ['select', 'insert', 'upsert', 'update', 'delete', 'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'ilike', 'is', 'in',
   'contains', 'filter', 'not', 'match', 'or', 'order', 'limit', 'range', 'single', 'maybeSingle', 'abortSignal', 'throwOnError', 'returns']
    .forEach(function (m) { Q.prototype[m] = function () { this.chain.push([m, Array.prototype.slice.call(arguments)]); return this; }; });
  Q.prototype.then = function (res, rej) { return run(this.t, this.chain).then(res, rej); };
  Q.prototype.catch = function (rej) { return this.then(null, rej); };
  Q.prototype.finally = function (f) { return this.then(function (v) { f(); return v; }, function (e) { f(); throw e; }); };

  function rpc(fn, args) {
    function offlinePath() {
      if (WRITES_ON && QUEUE_RPC[fn]) {
        return ready.then(function () { return enqueue({ kind: 'rpc', fn: fn, args: clone(args || {}), at: nowIso() }); })
          .then(function () { return { data: { queued: true }, error: null, status: 200 }; });
      }
      return Promise.resolve(netResult());
    }
    if (isOffline()) return offlinePath();
    return Promise.resolve(REAL.rpc(fn, args)).then(function (r) {
      if (isNetErr(r)) { markOffline(); return offlinePath(); }
      markOnline();
      return r;
    }, function () { markOffline(); return offlinePath(); });
  }

  // Sesión guardada en el iPhone (para no echarte a la pantalla de entrar sin cobertura)
  function storedSession() {
    try {
      var raw = localStorage.getItem(AUTH_KEY);
      if (!raw) return null;
      var s = JSON.parse(raw);
      if (s && s.currentSession) s = s.currentSession;
      return (s && s.user) ? s : null;
    } catch (e) { return null; }
  }
  function patchAuth(auth) {
    var realGet = auth.getSession.bind(auth);
    auth.getSession = function () {
      var stored = storedSession();
      if (isOffline() && stored) return Promise.resolve({ data: { session: stored }, error: null });
      var p = Promise.resolve(realGet()).catch(function (e) { return { data: { session: null }, error: e }; });
      if (!stored) return p;
      var timer;
      var expired = stored.expires_at && (stored.expires_at * 1000 < Date.now() + 10000);
      var slow = new Promise(function (res) { timer = setTimeout(function () { res('slow'); }, expired ? SESSION_WAIT_MS * 2 : SESSION_WAIT_MS); });
      return Promise.race([p, slow]).then(function (r) {
        clearTimeout(timer);
        if (r === 'slow') { markOffline(); return { data: { session: stored }, error: null }; }
        if (r && r.data && r.data.session) return r;
        if (r && r.error && (NET_RE.test(String(r.error.message || '')) || /retryable/i.test(String(r.error.name || '')))) {
          markOffline();
          return { data: { session: storedSession() || stored }, error: null };
        }
        return r;
      });
    };
  }

  // Red con tiempo límite: si no responde, se trata como «sin conexión»
  function timeoutFetch(input, init) {
    init = init || {};
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var method = String(init.method || (input && input.method) || 'GET').toUpperCase();
    var ms = /\/rest\/v1\/rpc\//.test(url) ? 90000 : /\/auth\/v1\//.test(url) ? 15000 : (method === 'GET' || method === 'HEAD') ? 15000 : 25000;
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, ms);
    if (init.signal) { if (init.signal.aborted) ctl.abort(); else init.signal.addEventListener('abort', function () { ctl.abort(); }); }
    return fetch(input, Object.assign({}, init, { signal: ctl.signal })).then(function (r) { clearTimeout(timer); return r; }, function (e) { clearTimeout(timer); throw e; });
  }

  var origCreate = window.supabase.createClient;
  window.supabase.createClient = function (url, key, opts) {
    opts = opts || {};
    opts.global = Object.assign({}, opts.global || {}, { fetch: timeoutFetch });
    REAL = origCreate(url, key, opts);
    patchAuth(REAL.auth);
    var client = {
      from: function (t) { return new Q(t); },
      rpc: rpc,
      auth: REAL.auth,
      channel: function () { return REAL.channel.apply(REAL, arguments); },
      removeChannel: function () { return REAL.removeChannel.apply(REAL, arguments); },
      storage: REAL.storage,
      functions: REAL.functions,
      __real: REAL
    };
    setTimeout(function () { startup(); }, 0);
    return client;
  };

  // ------------------------------------------------------- cola y sincronización
  function enqueue(op) {
    return idbAdd('outbox', op).then(function () { outboxN++; emitStatus(); scheduleSync(1500); });
  }

  function replayOp(op) {
    if (op.kind === 'rpc') return Promise.resolve(REAL.rpc(op.fn, op.args)).catch(function (e) { return { data: null, error: mkErr(String(e && e.message || e)), status: 0 }; });
    return replayReal(op.t, op.chain);
  }
  function alreadyDone(op, r) {
    // Inserción repetida (mismo id) o cobro ya existente: ya estaba en el servidor
    if (!r || !r.error) return false;
    var isInsert = op.kind === 'from' && op.chain.some(function (c) { return c[0] === 'insert'; });
    return isInsert && (String(r.error.code) === '23505' || r.status === 409);
  }

  var syncTimer = null;
  function scheduleSync(ms) { clearTimeout(syncTimer); syncTimer = setTimeout(sync, ms || 0); }

  function sync() {
    if (syncing || !REAL || navigator.onLine === false) return Promise.resolve();
    syncing = true; emitStatus();
    var done = 0;
    return idbAll('outbox').then(function (ops) {
      ops = (ops || []).sort(function (a, b) { return a.seq - b.seq; });
      var chainP = Promise.resolve(false);
      ops.forEach(function (op) {
        chainP = chainP.then(function (stop) {
          if (stop) return true;
          return replayOp(op).then(function (r) {
            if (isNetErr(r)) { markOffline(); return true; }        // sigue sin red: se reintenta luego
            if (!r.error || alreadyDone(op, r)) {
              done++; outboxN = Math.max(0, outboxN - 1);
              return idbDel('outbox', op.seq).then(function () { emitStatus(); return false; });
            }
            // Error del servidor (p. ej. depósito firmado): se aparta para revisarlo
            op.error = (r.error.message || 'Error') + (r.error.code ? ' (' + r.error.code + ')' : '');
            outboxN = Math.max(0, outboxN - 1); failedN++;
            return idbPut('failed', op).then(function () { return idbDel('outbox', op.seq); }).then(function () { emitStatus(); return false; });
          });
        });
      });
      return chainP;
    }).then(function () {
      syncing = false;
      if (done) markOnline();
      emitStatus();
      if (done) {
        try { window.dispatchEvent(new CustomEvent('mf:synced', { detail: { n: done } })); } catch (e) { /* noop */ }
        showNote('✓ ' + done + (done === 1 ? ' cambio subido' : ' cambios subidos') + ' al servidor');
      }
      if (outboxN === 0) { if (done || MIRROR_REFRESH_ON) refreshMirror(true); }
      else scheduleSync(20000);
    }, function (e) { syncing = false; emitStatus(); console.warn('[offline] sincronización', e); scheduleSync(20000); });
  }

  // Descarga completa de las tablas que usa Depósitos (paginada)
  var refreshing = false;
  function fetchTable(t) {
    var rows = [], size = 500;
    function page(from) {
      return Promise.resolve(REAL.from(t).select('*', { count: 'exact' }).order(MIRROR[t]).range(from, from + size - 1)).then(function (r) {
        if (r.error) throw r.error;
        rows = rows.concat(r.data || []);
        if (!r.data || !r.data.length) return rows;
        if (r.count != null ? rows.length >= r.count : r.data.length < size) return rows;
        return page(from + size);
      });
    }
    return page(0);
  }
  function refreshMirror(force) {
    if (refreshing || !REAL || isOffline()) return Promise.resolve();
    if (!force && Date.now() - M.at < REFRESH_EVERY_MS) return Promise.resolve();
    if (outboxN > 0) return Promise.resolve();            // primero hay que subir lo pendiente
    refreshing = true;
    return REAL.auth.getSession().then(function (s) {
      if (!s || !s.data || !s.data.session) throw new Error('sin sesión');
      var names = Object.keys(MIRROR), got = {};
      return names.reduce(function (p, n) {
        return p.then(function () { return fetchTable(n).then(function (rows) { got[n] = rows; }); });
      }, Promise.resolve()).then(function () {
        if (outboxN > 0) return;                           // se guardó algo mientras tanto: no pisarlo
        names.forEach(function (n) { M.tables[n] = got[n]; });
        M.at = Date.now();
        return Promise.all(names.map(function (n) { return idbPut('mirror', { name: n, rows: got[n] }); }))
          .then(function () { return idbPut('mirror', { name: '__meta', at: M.at }); });
      });
    }).then(function () { refreshing = false; emitStatus(); }, function (e) {
      refreshing = false;
      if (e && NET_RE.test(String(e.message || ''))) markOffline();
      console.warn('[offline] copia no actualizada', e && e.message || e);
    });
  }

  function startup() {
    ready.then(function () {
      emitStatus();
      if (outboxN > 0) scheduleSync(2000);
      else if (MIRROR_REFRESH_ON) setTimeout(function () { refreshMirror(false); }, 2500);
    });
  }
  window.addEventListener('online', function () { latchUntil = 0; emitStatus(); scheduleSync(800); });
  window.addEventListener('offline', function () { emitStatus(); });
  // Al salir de la página, que no quede nada sin escribir en el iPhone
  window.addEventListener('pagehide', function () { if (Object.keys(dirty).length) flushMirror(); });
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'hidden' && Object.keys(dirty).length) flushMirror(); });
  setInterval(function () { if (outboxN > 0 && !syncing && !isOffline()) sync(); }, 30000);

  // ------------------------------------------------------------- aviso en pantalla
  var bar = null, note = null, noteTimer = null;
  function el() {
    if (bar || !document.body) return bar;
    var st = document.createElement('style');
    st.textContent = '#mf-net{position:fixed;left:50%;transform:translateX(-50%);bottom:calc(12px + env(safe-area-inset-bottom));z-index:2147482000;'
      + 'max-width:calc(100vw - 24px);display:none;align-items:center;gap:8px;padding:8px 14px;border-radius:999px;'
      + 'font:600 12.5px/1.3 "Inter Tight",-apple-system,system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.45);cursor:default}'
      + '#mf-net.off{background:#3a2a0e;color:#f6d79b;border:1px solid #d4a04a}'
      + '#mf-net.sync{background:#0f2a24;color:#8fefd5;border:1px solid #4ab9a0}'
      + '#mf-net.fail{background:#3a1512;color:#ffb3a6;border:1px solid #e07560;cursor:pointer}'
      + '#mf-note{position:fixed;left:50%;transform:translateX(-50%);top:calc(10px + env(safe-area-inset-top));z-index:2147482001;display:none;'
      + 'background:#0f2a24;color:#8fefd5;border:1px solid #4ab9a0;padding:8px 14px;border-radius:999px;font:600 12.5px/1.3 "Inter Tight",-apple-system,system-ui,sans-serif;max-width:calc(100vw - 24px)}';
    document.head.appendChild(st);
    bar = document.createElement('div'); bar.id = 'mf-net'; bar.setAttribute('role', 'status'); bar.setAttribute('aria-live', 'polite');
    bar.addEventListener('click', function () { if (failedN) showFailed(); });
    note = document.createElement('div'); note.id = 'mf-note'; note.setAttribute('role', 'status');
    document.body.appendChild(bar); document.body.appendChild(note);
    return bar;
  }
  function hhmm(ts) { try { return new Date(ts).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
  function emitStatus() {
    if (!document.body) { document.addEventListener('DOMContentLoaded', emitStatus, { once: true }); return; }
    var b = el(); if (!b) return;
    var off = isOffline(), cls = '', txt = '';
    var pend = outboxN ? ' · ' + outboxN + (outboxN === 1 ? ' cambio por subir' : ' cambios por subir') : '';
    if (failedN) { cls = 'fail'; txt = '⚠ ' + failedN + (failedN === 1 ? ' cambio no se pudo subir' : ' cambios no se pudieron subir') + ' · toca para ver'; }
    else if (off) { cls = 'off'; txt = '📴 Sin conexión' + (M.at ? ' · datos de las ' + hhmm(M.at) : '') + pend; }
    else if (outboxN) { cls = 'sync'; txt = '↻ Subiendo ' + outboxN + (outboxN === 1 ? ' cambio…' : ' cambios…'); }
    b.className = cls; b.textContent = txt; b.style.display = cls ? 'flex' : 'none';
    try { window.dispatchEvent(new CustomEvent('mf:net', { detail: { offline: off, pending: outboxN, failed: failedN } })); } catch (e) { /* noop */ }
  }
  function showNote(msg) {
    el(); if (!note) return;
    note.textContent = msg; note.style.display = 'block';
    clearTimeout(noteTimer); noteTimer = setTimeout(function () { note.style.display = 'none'; }, 3500);
  }
  function showFailed() {
    idbAll('failed').then(function (list) {
      list = list || [];
      var txt = list.map(function (op, i) {
        var what = op.kind === 'rpc' ? 'función ' + op.fn : (op.t + ' · ' + ((op.chain.find(function (c) { return /insert|upsert|update|delete/.test(c[0]); }) || ['?'])[0]));
        return (i + 1) + '. ' + what + ' (' + (op.at || '').slice(0, 16).replace('T', ' ') + '): ' + op.error;
      }).join('\n');
      var keep = confirm('Estos cambios hechos sin conexión no se pudieron subir:\n\n' + txt +
        '\n\nAceptar = descargar una copia para revisarlos y quitarlos de la lista.\nCancelar = dejarlos como están.');
      if (!keep) return;
      var blob = new Blob([JSON.stringify(list, null, 2)], { type: 'application/json' });
      var a = document.createElement('a'); a.href = URL.createObjectURL(blob);
      a.download = 'magilu-cambios-no-subidos-' + nowIso().slice(0, 10) + '.json';
      document.body.appendChild(a); a.click(); a.remove();
      return Promise.all(list.map(function (op) { return idbDel('failed', op.seq); })).then(function () { failedN = 0; emitStatus(); });
    });
  }

  // El service worker (precarga de páginas y librerías) se registra desde todas las páginas
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('./sw.js').catch(function (e) { console.warn('[offline] service worker', e); });
    });
  }

  window.MFOffline = {
    isOffline: isOffline,
    pending: function () { return outboxN; },
    failed: function () { return failedN; },
    sync: function () { return sync(); },
    refresh: function () { return refreshMirror(true); },
    mirrorAt: function () { return M.at; },
    ready: ready
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', emitStatus, { once: true }); else emitStatus();
})();
