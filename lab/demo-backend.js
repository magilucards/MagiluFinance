// Magilu LAB · backend de demostración
// Sustituye al cliente de Supabase SOLO en el LAB. Todo vive en el navegador (localStorage):
// no hay conexión con la Supabase real ni con Holded. Las facturas, firmas y envíos se simulan.
// Además, la CSP de cada página del LAB solo permite conectar con el propio dominio ('self').
(function () {
  'use strict';

  var KEY = 'magilu_lab_db_v1';
  var AUTH_KEY = 'magilu_lab_signed_out';
  var USER = { id: '00000000-0000-4000-8000-00000000d3e0', email: 'demo@magilu.lab', aud: 'authenticated', role: 'authenticated' };

  // ---------- utilidades ----------
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16);
    });
  }
  function clone(o) { return o == null ? o : JSON.parse(JSON.stringify(o)); }
  function nowIso() { return new Date().toISOString(); }
  function wait(v) { return new Promise(function (res) { setTimeout(function () { res(v); }, 40); }); }
  function err(message, code) { return { message: message, code: code || 'DEMO', details: null, hint: null }; }

  // ---------- almacenamiento ----------
  var db = null;
  function load() {
    try { var raw = localStorage.getItem(KEY); if (raw) return JSON.parse(raw); } catch (e) { /* sin almacenamiento */ }
    return null;
  }
  function save() { try { localStorage.setItem(KEY, JSON.stringify(db)); } catch (e) { /* sin almacenamiento: solo memoria */ } }
  function table(name) { if (!db[name]) db[name] = []; return db[name]; }

  // Hooks por tabla (valores por defecto, triggers simulados, vistas, RPC). Los rellena demo-data.js.
  var H = window.MAGILU_DEMO_HOOKS || {};
  function initDb() {
    db = load();
    if (!db || db.__version !== (H.version || 1)) {
      db = H.seed ? H.seed({ uuid: uuid, user: USER }) : {};
      db.__version = H.version || 1;
      save();
    }
  }

  // ---------- comparaciones al estilo PostgREST ----------
  function norm(v) { return v; }
  function cmp(a, b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;           // nulls last por defecto
    if (b == null) return -1;
    if (typeof a === 'number' || typeof b === 'number') {
      var na = Number(a), nb = Number(b);
      if (!isNaN(na) && !isNaN(nb)) return na < nb ? -1 : na > nb ? 1 : 0;
    }
    if (typeof a === 'boolean' || typeof b === 'boolean') { a = String(a); b = String(b); }
    a = String(a); b = String(b);
    return a < b ? -1 : a > b ? 1 : 0;
  }
  function eqv(a, b) {
    if (a == null || b == null) return false;   // en SQL, = NULL nunca es cierto
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
  function containsv(a, b) {
    if (a == null) return false;
    if (Array.isArray(b)) return Array.isArray(a) && b.every(function (x) { return a.some(function (y) { return JSON.stringify(y) === JSON.stringify(x); }); });
    if (typeof b === 'object') return Object.keys(b).every(function (k) { return JSON.stringify(a[k]) === JSON.stringify(b[k]); });
    return String(a).indexOf(String(b)) >= 0;
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
      case 'cs': f = function (r) { return containsv(r[col], typeof val === 'string' ? JSON.parse(val.replace(/^\{/, '[').replace(/\}$/, ']')) : val); }; break;
      default: f = function () { return true; };
    }
    return neg ? function (r) { return !f(r); } : f;
  }

  function project(row, cols) {
    if (!cols || cols.trim() === '*') return clone(row);
    var out = {};
    cols.split(',').forEach(function (c) {
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

  // ---------- query builder ----------
  function Query(name) {
    this.t = name; this.op = 'select'; this.filters = []; this.orders = [];
    this.lim = null; this.rng = null; this.cols = '*'; this.one = 0;
    this.countOpt = null; this.head = false; this.payload = null; this.returning = false; this.onConflict = null;
  }
  var Q = Query.prototype;
  Q._f = function (fn) { this.filters.push(fn); return this; };
  Q.select = function (cols, opts) {
    opts = opts || {};
    if (this.op === 'select') { this.cols = cols || '*'; this.countOpt = opts.count || null; this.head = !!opts.head; }
    else { this.returning = true; this.cols = cols || '*'; }
    return this;
  };
  Q.insert = function (v) { this.op = 'insert'; this.payload = v; return this; };
  Q.upsert = function (v, o) { this.op = 'upsert'; this.payload = v; this.onConflict = o && o.onConflict; return this; };
  Q.update = function (v) { this.op = 'update'; this.payload = v; return this; };
  Q.delete = function () { this.op = 'delete'; return this; };
  ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'ilike', 'is'].forEach(function (op) {
    Q[op] = function (c, v) { return this._f(opFn(op, c, v)); };
  });
  Q.in = function (c, v) { return this._f(opFn('in', c, v)); };
  Q.contains = function (c, v) { return this._f(function (r) { return containsv(r[c], v); }); };
  Q.filter = function (c, op, v) { return this._f(opFn(op, c, v)); };
  Q.not = function (c, op, v) { return this._f(opFn('not.' + op, c, v)); };
  Q.match = function (o) { var s = this; Object.keys(o).forEach(function (k) { s.eq(k, o[k]); }); return s; };
  Q.or = function (expr) {
    var parts = String(expr).split(/,(?![^(]*\))/).map(function (p) {
      var m = p.match(/^([a-zA-Z0-9_]+)\.((?:not\.)?[a-z]+)\.(.*)$/);
      return m ? opFn(m[2], m[1], m[3]) : function () { return false; };
    });
    return this._f(function (r) { return parts.some(function (f) { return f(r); }); });
  };
  Q.order = function (c, o) { o = o || {}; this.orders.push({ c: c, asc: o.ascending !== false, nf: o.nullsFirst }); return this; };
  Q.limit = function (n) { this.lim = n; return this; };
  Q.range = function (a, b) { this.rng = [a, b]; return this; };
  Q.single = function () { this.one = 1; return this; };
  Q.maybeSingle = function () { this.one = 2; return this; };
  Q.abortSignal = function () { return this; };
  Q.throwOnError = function () { this._throw = true; return this; };
  Q.then = function (res, rej) {
    var self = this;
    var p = wait().then(function () {
      try { return self._exec(); } catch (e) { var pe = (e && e.message && !(e instanceof Error)) ? e : err(e.message || String(e), e.code); return { data: null, error: pe, count: null, status: pe.status || 400 }; }
    }).then(function (r) { if (self._throw && r.error) throw r.error; return r; });
    return p.then(res, rej);
  };
  Q.catch = function (rej) { return this.then(null, rej); };

  Q._rows = function () {
    var view = H.views && H.views[this.t];
    var rows = view ? view(db, ctx) : table(this.t);
    var fs = this.filters;
    return rows.filter(function (r) { return fs.every(function (f) { return f(r); }); });
  };

  Q._exec = function () {
    var self = this, rows, out, count = null;
    var hooks = (H.tables && H.tables[this.t]) || {};

    if (this.op === 'select') {
      rows = this._rows().slice();
      if (this.orders.length) {
        var os = this.orders;
        rows.sort(function (a, b) {
          for (var i = 0; i < os.length; i++) {
            var o = os[i], x = a[o.c], y = b[o.c];
            if (x == null || y == null) {
              if (x == null && y == null) continue;
              var nf = o.nf != null ? o.nf : !o.asc;    // PostgreSQL: NULLS LAST en ASC, FIRST en DESC
              return (x == null) === nf ? -1 : 1;
            }
            var c = cmp(x, y); if (c) return o.asc ? c : -c;
          }
          return 0;
        });
      }
      if (this.countOpt) count = rows.length;
      if (this.rng) rows = rows.slice(this.rng[0], this.rng[1] + 1);
      if (this.lim != null) rows = rows.slice(0, this.lim);
      out = this.head ? null : rows.map(function (r) { return project(r, self.cols); });
    } else if (this.op === 'insert' || this.op === 'upsert') {
      var list = Array.isArray(this.payload) ? this.payload : [this.payload];
      var t = table(this.t);
      rows = list.map(function (v) {
        var row = clone(v);
        if (self.op === 'upsert') {
          var keys = self.onConflict ? self.onConflict.split(',').map(function (s) { return s.trim(); }) : ['id'];
          var ex = t.find(function (r) { return keys.every(function (k) { return row[k] != null && eqv(r[k], row[k]); }); });
          if (ex) { Object.assign(ex, row, { updated_at: nowIso() }); if (hooks.afterWrite) hooks.afterWrite(db, ex, ctx); return ex; }
        }
        if (row.id == null) row.id = hooks.idType === 'int' ? (t.reduce(function (m, r) { return Math.max(m, +r.id || 0); }, 0) + 1) : uuid();
        if (row.created_at == null) row.created_at = nowIso();
        if (row.user_id === undefined && hooks.userScoped !== false) row.user_id = USER.id;
        if (hooks.defaults) hooks.defaults(row, db, ctx);
        if (hooks.beforeInsert) { var e1 = hooks.beforeInsert(row, db, ctx); if (e1) throw e1; }
        t.push(row);
        if (hooks.afterWrite) hooks.afterWrite(db, row, ctx);
        return row;
      });
      save();
      out = this.returning ? rows.map(function (r) { return project(r, self.cols); }) : null;
    } else if (this.op === 'update') {
      rows = this._rows();
      rows.forEach(function (r) {
        if (hooks.beforeUpdate) { var e2 = hooks.beforeUpdate(r, self.payload, db, ctx); if (e2) throw e2; }
      });
      rows.forEach(function (r) {
        Object.assign(r, clone(self.payload));
        if ('updated_at' in r || hooks.touch) r.updated_at = nowIso();
        if (hooks.afterWrite) hooks.afterWrite(db, r, ctx);
      });
      save();
      out = this.returning ? rows.map(function (r) { return project(r, self.cols); }) : null;
    } else if (this.op === 'delete') {
      rows = this._rows();
      rows.forEach(function (r) { if (hooks.beforeDelete) { var e3 = hooks.beforeDelete(r, db, ctx); if (e3) throw e3; } });
      var t2 = table(this.t);
      db[this.t] = t2.filter(function (r) { return rows.indexOf(r) < 0; });
      rows.forEach(function (r) { if (hooks.afterDelete) hooks.afterDelete(db, r, ctx); });
      save();
      out = this.returning ? rows.map(function (r) { return project(r, self.cols); }) : null;
    }

    if (this.one) {
      var arr = out || [];
      if (arr.length === 1) out = arr[0];
      else if (arr.length === 0 && this.one === 2) out = null;
      else return { data: null, error: err('JSON object requested, multiple (or no) rows returned', 'PGRST116'), count: count, status: 406 };
    }
    return { data: out, error: null, count: count, status: 200, statusText: 'OK' };
  };

  // ---------- contexto para hooks / RPC ----------
  var ctx = {
    uuid: uuid, user: USER, err: err, clone: clone, nowIso: nowIso, save: function () { save(); },
    table: function (n) { return table(n); }
  };

  // ---------- cliente ----------
  function signedOut() { try { return localStorage.getItem(AUTH_KEY) === '1'; } catch (e) { return false; } }
  function session() { return signedOut() ? null : { access_token: 'demo', token_type: 'bearer', user: clone(USER), expires_at: 4102444800 }; }
  var listeners = [];
  function emit(ev) { var s = session(); listeners.forEach(function (cb) { try { cb(ev, s); } catch (e) { /* noop */ } }); }

  function createClient() {
    if (!db) initDb();
    return {
      from: function (t) { return new Query(t); },
      rpc: function (fn, args) {
        return wait().then(function () {
          var impl = H.rpc && H.rpc[fn];
          if (!impl) return { data: null, error: err('Función "' + fn + '" no disponible en el modo demo') };
          try {
            var r = impl(args || {}, db, ctx);
            save();
            if (r && r.__error) return { data: null, error: r.__error };
            return { data: r === undefined ? null : r, error: null };
          } catch (e) { return { data: null, error: (e && e.message && !(e instanceof Error)) ? e : err(e.message || String(e), e.code) }; }
        });
      },
      functions: { invoke: function (n) { return wait({ data: null, error: err('Funciones remotas desactivadas en el modo demo (' + n + ')') }); } },
      storage: { from: function () { var no = function () { return wait({ data: null, error: err('Almacenamiento desactivado en el modo demo') }); }; return { upload: no, download: no, remove: no, list: no, getPublicUrl: function () { return { data: { publicUrl: '' } }; }, createSignedUrl: no }; } },
      channel: function () { var ch = { on: function () { return ch; }, subscribe: function () { return ch; }, unsubscribe: function () { return wait('ok'); } }; return ch; },
      removeChannel: function () { return wait('ok'); },
      auth: {
        getSession: function () { return wait({ data: { session: session() }, error: null }); },
        getUser: function () { var s = session(); return wait({ data: { user: s ? s.user : null }, error: s ? null : err('Sin sesión') }); },
        onAuthStateChange: function (cb) {
          listeners.push(cb);
          var s0 = session(); if (s0) setTimeout(function () { try { cb('INITIAL_SESSION', s0); } catch (e) { /* noop */ } }, 0);
          return { data: { subscription: { unsubscribe: function () { listeners = listeners.filter(function (x) { return x !== cb; }); } } } };
        },
        signInWithPassword: function () {
          try { localStorage.removeItem(AUTH_KEY); } catch (e) { /* noop */ }
          emit('SIGNED_IN');
          return wait({ data: { user: clone(USER), session: session() }, error: null });
        },
        signUp: function () { return wait({ data: { user: null, session: null }, error: err('En el modo demo no se crean cuentas: entra con cualquier email y contraseña.') }); },
        signOut: function () {
          try { localStorage.setItem(AUTH_KEY, '1'); } catch (e) { /* noop */ }
          emit('SIGNED_OUT');
          return wait({ error: null });
        },
        resetPasswordForEmail: function () { return wait({ data: null, error: err('No disponible en el modo demo') }); }
      }
    };
  }

  window.supabase = { createClient: createClient };
  window.MAGILU_DEMO = {
    reset: function () { try { localStorage.removeItem(KEY); } catch (e) { /* noop */ } db = null; },
    dump: function () { if (!db) initDb(); return clone(db); }
  };
})();
