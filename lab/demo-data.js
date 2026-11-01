// Magilu LAB · datos de prueba y simulación de la base de datos
// Se usa con lab/demo-backend.js. Todo es ficticio y vive en el navegador.
// Holded NO se llama nunca: facturar, enviar y registrar pagos se simulan aquí.
(function () {
  'use strict';

  // ---------- utilidades ----------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function ymd(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function today() { return ymd(new Date()); }
  function addDays(s, n) { var d = new Date(s + 'T12:00:00'); d.setDate(d.getDate() + n); return ymd(d); }
  function diffDays(a, b) { return Math.round((new Date(a + 'T12:00:00') - new Date(b + 'T12:00:00')) / 86400000); }
  function r2(x) { return Math.round((+x || 0) * 100) / 100; }
  function num(x) { return +x || 0; }
  function mulberry(seed) { return function () { seed |= 0; seed = seed + 0x6D2B79F5 | 0; var t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
  function fakeHash(str) {   // 64 hex (no criptográfico: solo para la demo)
    var out = '';
    for (var k = 0; k < 8; k++) {
      var h = 0x811c9dc5 ^ (k * 0x9e3779b1);
      for (var i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 0x01000193); }
      out += ('0000000' + (h >>> 0).toString(16)).slice(-8);
    }
    return out;
  }
  function E(message, code, status) { return { message: message, code: code || 'P0001', details: null, hint: null, status: status }; }
  function isTarjeta(code) { var c = String(code || '').toUpperCase(); return c.indexOf('MGE') === 0 || c.indexOf('MGI') === 0 || c.indexOf('NAVI') === 0; }
  function reRate(v) { v = num(v); return v === 21 ? 0.052 : v === 10 ? 0.014 : v === 4 ? 0.005 : 0; }
  function byId(list, id) { for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]; return null; }
  function sold(l) { return num(l.qty_delivered) - num(l.qty_remaining); }

  // ---------- vista v_deposit_totals ----------
  function depositTotals(db, d) {
    var c = byId(db.clients || [], d.client_id) || {};
    var lines = (db.deposit_lines || []).filter(function (l) { return l.deposit_id === d.id; });
    var hasRe = d.client_has_re != null ? !!d.client_has_re : c.vat_regime === 'recargo_equivalencia';
    var isB = (d.regime || 'A') === 'B';
    var t = { n_lines: lines.length, units_delivered: 0, units_sold: 0, importe_counted: 0, valor_deposito: 0, base: 0, iva: 0, re: 0 };
    lines.forEach(function (l) {
      var qd = num(l.qty_delivered), pr = num(l.unit_price), vat = l.vat_rate == null ? 21 : num(l.vat_rate);
      t.units_delivered += qd;
      t.valor_deposito += qd * pr;
      if (l.qty_remaining != null) { t.units_sold += qd - num(l.qty_remaining); t.importe_counted += (qd - num(l.qty_remaining)) * pr; }
      var b = (qd - num(l.qty_remaining)) * pr;
      t.base += b;
      if (!isB) { t.iva += b * vat / 100; if (hasRe) t.re += b * reRate(vat); }
    });
    var pc = (db.pending_collections || []).filter(function (p) { return p.deposit_id === d.id; })[0];
    var row = {};
    ['id', 'user_id', 'client_id', 'location_id', 'delivery_date', 'recount_date', 'invoice_date', 'status', 'regime', 'client_has_re',
      'payment_method', 'deposit_number', 'holded_invoice_id', 'holded_invoice_status', 'notes', 'client_note', 'created_at', 'updated_at']
      .forEach(function (k) { row[k] = d[k] === undefined ? null : d[k]; });
    row.dia = d.recount_date || d.invoice_date || d.delivery_date;
    row.has_re = hasRe;
    Object.keys(t).forEach(function (k) { row[k] = t[k]; });
    row.total = t.base + t.iva + t.re;
    row.collection_status = pc ? pc.status : null;
    return row;
  }
  function viewTotals(db) { return (db.deposits || []).map(function (d) { return depositTotals(db, d); }); }

  // ---------- recalc_daily_record ----------
  function recalcDaily(db, date, user) {
    var a = 0, b = 0;
    (db.deposits || []).forEach(function (d) {
      if (d.status !== 'facturado' || d.invoice_date !== date) return;
      var c = byId(db.clients || [], d.client_id) || {};
      var hasRe = d.client_has_re != null ? !!d.client_has_re : c.vat_regime === 'recargo_equivalencia';
      (db.deposit_lines || []).forEach(function (l) {
        if (l.deposit_id !== d.id) return;
        var base = sold(l) * num(l.unit_price), vat = l.vat_rate == null ? 21 : num(l.vat_rate);
        if (d.regime === 'A') a += base * (1 + vat / 100 + (hasRe ? reRate(vat) : 0));
        else if (d.regime === 'B') b += base;
      });
    });
    a = r2(a); b = r2(b);
    var recs = db.daily_records || (db.daily_records = []);
    var ex = recs.filter(function (r) { return r.record_date === date; })[0];
    if (!ex && a === 0 && b === 0) return { record_date: date, invoiced_a: 0, invoiced_b: 0, action: 'none' };
    if (ex) { ex.invoiced_a = a; ex.invoiced_b = b; ex.updated_at = new Date().toISOString(); return { record_date: date, invoiced_a: a, invoiced_b: b, action: 'updated' }; }
    recs.push({ id: uid(), user_id: user.id, record_date: date, invoiced_a: a, invoiced_b: b, collected_a: 0, collected_b: 0, notes: null, cash_account_id: null, cash_movement_id: null, created_at: new Date().toISOString() });
    return { record_date: date, invoiced_a: a, invoiced_b: b, action: 'created' };
  }

  // ---------- instantánea para firmas ----------
  function snapshot(db, d, moment) {
    var c = byId(db.clients || [], d.client_id) || {};
    var loc = d.location_id ? byId(db.client_locations || [], d.location_id) : null;
    var lines = (db.deposit_lines || []).filter(function (l) { return l.deposit_id === d.id; })
      .sort(function (x, y) { return num(x.sort_order) - num(y.sort_order) || String(x.product_code).localeCompare(String(y.product_code)); });
    return {
      deposito: d.deposit_number, momento: moment, fecha_entrega: d.delivery_date, fecha_recuento: d.recount_date,
      cliente: { razon_social: c.legal_name || null, nif: c.nif || null, nombre_comercial: c.commercial_name || null },
      tienda: loc ? { nombre: loc.name, direccion: loc.address, poblacion: loc.city, cp: loc.postal_code } : null,
      nota_cliente: d.client_note || null,
      lineas: lines.map(function (l) {
        return { codigo: l.product_code, producto: l.product_name, entregadas: num(l.qty_delivered),
          quedan: l.qty_remaining == null ? null : num(l.qty_remaining),
          vendidas: l.qty_remaining == null ? null : sold(l), precio: num(l.unit_price), iva: l.vat_rate == null ? 21 : num(l.vat_rate) };
      })
    };
  }

  var uid = function () {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); });
  };
  var PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  // ---------- datos iniciales ----------
  function seed(o) {
    var U = o.user.id, rnd = mulberry(20261101), T = today(), now = new Date().toISOString();
    function pick(a) { return a[Math.floor(rnd() * a.length)]; }
    function ri(a, b) { return a + Math.floor(rnd() * (b - a + 1)); }
    var db = { settings: [], products: [], clients: [], client_locations: [], deposits: [], deposit_lines: [], deposit_signatures: [],
      pending_collections: [], accounts: [], movements: [], daily_records: [], expenses: [] };

    db.settings.push({ id: uid(), user_id: U, margin_brut_pct: 60, target_monthly_salary: 2000,
      company_legal_name: 'Magilu Demo S.L.', company_cif: 'B00000000', creditor_iban: 'ES0000000000000000000000',
      creditor_bic: 'DEMOESXXXXX', creditor_sepa_id: 'ES00ZZZB00000000', next_deposit_number: 1001, created_at: now });

    // Productos
    var P = [
      ['MGE-STD', 'Tarjeta Magilu estándar', 2.95, 0.55, null],
      ['MGE-STD-AMOR', 'Tarjeta estándar · Amor', 2.95, 0.55, 'MGE-STD'],
      ['MGE-STD-CUMPLE', 'Tarjeta estándar · Cumpleaños', 2.95, 0.55, 'MGE-STD'],
      ['MGE-NEW', 'Tarjeta Magilu novedad', 3.50, 0.70, null],
      ['MGI-STD', 'Tarjeta infantil', 2.50, 0.45, null],
      ['NAVI-STD', 'Tarjeta Navidad', 2.95, 0.50, null],
      ['NAVI-PREM', 'Tarjeta Navidad premium', 4.50, 0.95, null],
      ['MAXI-01', 'Tarjeta maxi', 6.95, 1.60, null],
      ['MINI-01', 'Mini tarjeta regalo', 1.50, 0.25, null],
      ['LLAV-01', 'Llavero mariposa', 4.95, 1.20, null],
      ['ETIQ-01', 'Etiquetas regalo (pack)', 1.95, 0.35, null],
      ['MPT-01', 'Marcapáginas', 1.80, 0.30, null],
      ['CU-01', 'Cuaderno (descatalogado)', 3.90, 1.10, null]
    ];
    P.forEach(function (p) {
      db.products.push({ id: uid(), user_id: U, code: p[0], name: p[1], current_price: p[2], current_cost: p[3], reference_cost: p[3],
        parent_code: p[4], vat_rate: 21, notes: null, is_active: p[0] !== 'CU-01', created_at: now });
    });
    var sellable = db.products.filter(function (p) { return p.is_active && !p.parent_code; }).concat(db.products.filter(function (p) { return p.parent_code; }));

    // Contactos (ficticios)
    var C = [
      ['B00000001', 'Papelería La Mariposa S.L.', 'Papelería La Mariposa', 'Alicante', 'recargo_equivalencia', 'remesa_sepa', true],
      ['00000002T', 'Ana Ejemplo Pérez', 'Estanco Nº 7', 'Benidorm', 'recargo_equivalencia', 'efectivo', false],
      ['B00000003', 'Librería Rosa S.L.', 'Librería Rosa', 'Elche', 'general', 'transferencia', false],
      ['00000004R', 'Luis Demo García', 'Floristería Pétalo', 'Alicante', 'recargo_equivalencia', 'bizum', false],
      ['00000005W', 'Marta Prueba Ruiz', 'Bazar Las Palmeras', 'Torrevieja', 'recargo_equivalencia', 'efectivo', false],
      ['00000006A', 'Kiosko Central C.B.', 'Kiosko Central', 'San Vicente', 'recargo_equivalencia', 'tarjeta', false],
      ['B00000007', 'Regalos Luna S.L.', 'Regalos Luna', 'Alicante', 'general', 'remesa_sepa', true],
      ['00000008G', 'Pedro Muestra López', 'Papelería El Lápiz', 'Villena', 'recargo_equivalencia', 'transferencia', false],
      ['B00000009', 'Farmacia Demo S.L.', 'Farmacia Demo', 'Elda', 'general', 'tarjeta', false],
      ['B00000010', 'Imprenta Ficticia S.L.', 'Imprenta Ficticia', 'Alicante', 'general', 'transferencia', false],
      ['00000011M', 'Cliente Antiguo S.C.', 'Tienda cerrada', 'Alcoy', 'recargo_equivalencia', 'efectivo', false]
    ];
    C.forEach(function (c, i) {
      var iban = c[6] ? 'ES91210004184502000513' + pad(i + 10) : null;
      db.clients.push({ id: uid(), user_id: U, nif: c[0], legal_name: c[1], commercial_name: c[2], email: 'tienda' + (i + 1) + '@ejemplo.test',
        phone: '600 000 0' + pad(i + 1), address: 'Calle Ejemplo ' + (i + 3), city: c[3], postal_code: '03' + pad(i + 1) + '0', province: 'Alicante', country: 'ES',
        iban: iban, iban_last4: iban ? iban.slice(-4) : null, bic: iban ? 'CAIXESBBXXX' : null,
        sepa_mandate_ref: iban ? 'MGL-DEMO-' + pad(i + 1) : null, sepa_mandate_date: iban ? addDays(T, -200) : null, sepa_seq_type: iban ? 'RCUR' : null,
        vat_regime: c[4], payment_method: c[5], internal_notes: i === 4 ? 'MIXTO: a veces paga en B' : null,
        is_client: i !== 9, is_supplier: i === 9, is_active: i !== 10, requires_signature: i === 6, created_at: now, updated_at: now });
    });
    var cli = db.clients;
    function loc(ci, name, addr) {
      var l = { id: uid(), user_id: U, client_id: cli[ci].id, name: name, address: addr, city: cli[ci].city, postal_code: cli[ci].postal_code, is_active: true, created_at: now, updated_at: now };
      db.client_locations.push(l); return l;
    }
    var lunaLocs = [loc(6, 'Centro', 'Av. Demo 12'), loc(6, 'Playa', 'Paseo Ejemplo 4')];
    loc(0, 'Tienda principal', 'Calle Ejemplo 3');

    // Cuentas
    var A = [
      ['Cuenta principal', 'Banco Demo', '1234', 'operativa', 8420.35, null],
      ['Cuenta secundaria', 'Banco Ejemplo', '5678', 'operativa', 1260.10, null],
      ['Póliza de crédito', 'Banco Demo', '9012', 'poliza', -3500, 15000],
      ['Reserva Hacienda', 'Banco Demo', '3456', 'hacienda', 2140, null],
      ['Colchón', 'Banco Ejemplo', '7890', 'colchon', 3000, null],
      ['Caja efectivo', '', '', 'efectivo', 385.50, null]
    ];
    A.forEach(function (a, i) {
      db.accounts.push({ id: uid(), user_id: U, label: a[0], bank: a[1], last4: a[2], account_type: 'Cuenta corriente', kind: a[3],
        balance: a[4], credit_limit: a[5], sort_order: i + 1, created_at: now, updated_at: now });
    });
    var acc = db.accounts;

    // Depósitos (últimos ~4 meses)
    var deps = [];
    for (var i = 0; i < 38; i++) {
      var ci = pick([0, 0, 1, 2, 3, 4, 5, 6, 6, 7, 8, 1, 3, 5]);
      deps.push({ ci: ci, delivery: addDays(T, -ri(2, 125)) });
    }
    deps.sort(function (a, b) { return a.delivery < b.delivery ? -1 : 1; });
    deps.forEach(function (x, k) {
      var c = cli[x.ci];
      var age = diffDays(T, x.delivery);
      var d = { id: uid(), user_id: U, client_id: c.id, location_id: x.ci === 6 ? pick(lunaLocs).id : null,
        delivery_date: x.delivery, recount_date: null, invoice_date: null, status: 'abierto', regime: null, client_has_re: null,
        payment_method: null, deposit_number: 1001 + k, holded_invoice_id: null, holded_invoice_status: null,
        notes: null, client_note: k % 7 === 0 ? 'Reponer sobre todo cumpleaños' : null, created_at: x.delivery + 'T09:00:00.000Z', updated_at: x.delivery + 'T09:00:00.000Z' };
      if (age > 20) {
        d.recount_date = addDays(x.delivery, Math.min(ri(14, 30), age - 1));
        if (age >= 21 && age <= 30) d.recount_date = T;   // algunas liquidaciones hoy, para que el mes en curso tenga datos
        d.regime = (x.ci === 4 && rnd() < 0.6) || (x.ci === 1 && rnd() < 0.3) ? 'B' : 'A';
        var pm = c.payment_method === 'remesa_sepa' ? 'remesa' : c.payment_method;
        d.payment_method = d.regime === 'B' ? 'efectivo' : pm;
        if (d.regime === 'A' && !(diffDays(T, d.recount_date) < 6 && rnd() < 0.7)) {
          d.status = 'facturado'; d.invoice_date = d.recount_date;
          d.holded_invoice_id = 'demo-' + d.deposit_number; d.holded_invoice_status = 'emitida';
        } else d.status = 'recontado';
      }
      db.deposits.push(d);
      // líneas
      var n = ri(3, 5), used = {};
      for (var j = 0; j < n; j++) {
        var p = pick(sellable); if (used[p.code]) continue; used[p.code] = 1;
        var qd = pick([20, 24, 30, 40, 50, 60, 100, 120]);
        if (p.code.indexOf('NAVI') === 0 && new Date(x.delivery).getMonth() < 9) qd = pick([20, 30]);
        db.deposit_lines.push({ id: uid(), user_id: U, deposit_id: d.id, product_id: p.id, product_code: p.code, product_name: p.name,
          qty_delivered: qd, qty_remaining: d.recount_date ? Math.floor(qd * (0.15 + rnd() * 0.55)) : null,
          unit_price: p.current_price, unit_cost: p.current_cost, vat_rate: p.vat_rate, sort_order: j + 1, created_at: d.created_at, updated_at: d.created_at });
      }
    });

    // Cobros pendientes / cobrados
    db.deposits.forEach(function (d) {
      if (d.status === 'abierto') return;
      var t = depositTotals(db, d);
      if (t.total <= 0) return;
      var inv = d.invoice_date || d.recount_date, age = diffDays(T, inv);
      var immediate = ['efectivo', 'tarjeta', 'bizum'].indexOf(d.payment_method) >= 0;
      var st = immediate ? 'cobrado' : (age > 35 ? 'cobrado' : 'pendiente');
      if (d.deposit_number % 13 === 0 && !immediate) st = 'incidencia';
      var c = byId(cli, d.client_id);
      db.pending_collections.push({ id: uid(), user_id: U, deposit_id: d.id, daily_record_id: null, invoice_date: inv,
        expected_date: immediate ? inv : addDays(inv, 30), amount: r2(t.total), regime: d.regime || 'A', payment_method: d.payment_method,
        client_name: c.commercial_name || c.legal_name, status: st, notes: st === 'incidencia' ? 'Devolución de recibo (demo)' : null,
        collected_date: st === 'cobrado' ? (immediate ? inv : addDays(inv, 30)) : null,
        collected_account_id: st === 'cobrado' ? (d.payment_method === 'efectivo' ? acc[5].id : acc[0].id) : null, collected_movement_id: null,
        remesa_exported_at: null, remesa_file_ref: null, created_at: inv + 'T18:00:00.000Z' });
    });

    // Registros diarios desde lo facturado
    var dias = {};
    db.deposits.forEach(function (d) { if (d.status === 'facturado') dias[d.invoice_date] = 1; });
    Object.keys(dias).forEach(function (dia) { recalcDaily(db, dia, o.user); });
    db.daily_records.forEach(function (r) { if (diffDays(T, r.record_date) > 7) { r.collected_a = r.invoiced_a; r.collected_b = r.invoiced_b; } });

    // Firmas para el cliente que las exige
    db.deposits.forEach(function (d) {
      if (d.client_id !== cli[6].id) return;
      var ms = d.status === 'abierto' ? ['entrega'] : ['entrega', 'recuento'];
      ms.forEach(function (m) {
        var snap = snapshot(db, d, m);
        db.deposit_signatures.push({ id: uid(), user_id: U, deposit_id: d.id, moment: m, signer_name: 'Encargada demo', signature_png: PNG,
          content_snapshot: snap, content_hash: fakeHash(JSON.stringify(snap)), device_info: 'demo',
          signed_at: (m === 'entrega' ? d.delivery_date : d.recount_date) + 'T10:30:00.000Z', voided_at: null, void_reason: null, created_at: now });
      });
    });

    // Movimientos
    var MV = [
      ['ingreso', null, 0, 1250, 'Cobro remesa (demo)'], ['gasto', 0, null, 320.40, 'Imprenta (demo)'], ['traspaso', 0, 3, 600, 'Provisión IVA'],
      ['gasto', 0, null, 89.90, 'Gasoil'], ['amortizacion', 0, 2, 500, 'Amortización póliza'], ['ingreso', null, 1, 410, 'Transferencia cliente'],
      ['iva', 3, null, 1480, 'Pago trimestral IVA'], ['traspaso', 1, 4, 300, 'Al colchón'], ['gasto', 5, null, 25, 'Parking'],
      ['ingreso', null, 5, 185, 'Efectivo ruta'], ['gasto', 0, null, 59.99, 'Material'], ['ingreso', null, 0, 960, 'Cobro remesa (demo)']
    ];
    MV.forEach(function (m, k) {
      var dt = addDays(T, -ri(1, 60));
      db.movements.push({ id: uid(), user_id: U, mov_date: dt, mov_type: m[0], origin_account_id: m[1] == null ? null : acc[m[1]].id,
        dest_account_id: m[2] == null ? null : acc[m[2]].id, amount: m[3], concept: m[4], created_at: dt + 'T12:' + pad(k) + ':00.000Z' });
    });

    // Gastos de ruta
    var G = [['Gasoil', 45, 85], ['Peajes', 4, 18], ['Parking', 2, 12], ['Comida', 9, 22], ['Material', 10, 60], ['Otros', 5, 30]];
    for (var g = 0; g < 26; g++) {
      var gg = pick(G), dt2 = addDays(T, -ri(0, 75));
      db.expenses.push({ id: uid(), user_id: U, expense_date: dt2, concept: gg[0], amount: r2(gg[1] + rnd() * (gg[2] - gg[1])), notes: null, created_at: dt2 + 'T19:00:00.000Z' });
    }
    return db;
  }

  // ---------- reglas por tabla (triggers / restricciones simuladas) ----------
  function unique(col, msgCode) {
    return function (row, db, tableName, selfId) {
      if (row[col] == null || row[col] === '') return null;
      var dup = (db[tableName] || []).some(function (r) { return r.id !== selfId && String(r[col]).trim().toLowerCase() === String(row[col]).trim().toLowerCase(); });
      return dup ? E('duplicate key value violates unique constraint "' + tableName + '_' + col + '_key"', '23505', 409) : null;
    };
  }
  var uNif = unique('nif'), uCode = unique('code'), uDep = unique('deposit_id');
  function locDup(row, db, selfId) {
    var dup = (db.client_locations || []).some(function (l) { return l.id !== selfId && l.client_id === row.client_id && String(l.name || '').trim().toLowerCase() === String(row.name || '').trim().toLowerCase(); });
    return dup ? E('duplicate key value violates unique constraint "client_locations_client_name_uidx"', '23505', 409) : null;
  }
  function rumAndLast4(db, r) {
    if (r.iban && !r.sepa_mandate_ref) { r.sepa_mandate_ref = 'MGL-DEMO-' + String(Date.now()).slice(-6); if (!r.sepa_mandate_date) r.sepa_mandate_date = today(); }
    if (r.iban) r.iban_last4 = String(r.iban).replace(/\s/g, '').slice(-4);
  }

  var tables = {
    clients: {
      defaults: function (r) { if (r.requires_signature == null) r.requires_signature = false; if (r.country == null) r.country = 'ES'; if (r.is_active == null) r.is_active = true; },
      beforeInsert: function (r, db) { return uNif(r, db, 'clients', null); },
      beforeUpdate: function (r, patch, db) { return 'nif' in patch ? uNif(Object.assign({}, r, patch), db, 'clients', r.id) : null; },
      afterWrite: rumAndLast4,
      afterDelete: function (db, r) { db.client_locations = (db.client_locations || []).filter(function (l) { return l.client_id !== r.id; }); }
    },
    products: {
      beforeInsert: function (r, db) { return uCode(r, db, 'products', null); },
      beforeUpdate: function (r, patch, db) { return 'code' in patch ? uCode(Object.assign({}, r, patch), db, 'products', r.id) : null; }
    },
    client_locations: {
      touch: true,
      defaults: function (r) { if (r.is_active == null) r.is_active = true; r.updated_at = r.created_at; },
      beforeInsert: function (r, db) { return String(r.name || '').trim() ? locDup(r, db, null) : E('El nombre de la tienda es obligatorio', '23514', 400); },
      beforeUpdate: function (r, patch, db) { return ('name' in patch) ? locDup(Object.assign({}, r, patch), db, r.id) : null; }
    },
    pending_collections: {
      beforeInsert: function (r, db) {
        if (!(num(r.amount) > 0)) return E('new row violates check constraint "pending_collections_amount_check"', '23514', 400);
        return uDep(r, db, 'pending_collections', null);
      }
    },
    deposits: {
      touch: true,
      beforeDelete: function (r, db) {
        if ((db.deposit_signatures || []).some(function (s) { return s.deposit_id === r.id; }))
          return E('update or delete on table "deposits" violates foreign key constraint on table "deposit_signatures"', '23503', 409);
        return null;
      },
      afterDelete: function (db, r) { db.deposit_lines = (db.deposit_lines || []).filter(function (l) { return l.deposit_id !== r.id; }); }
    },
    deposit_lines: { touch: true, defaults: function (r) { if (r.vat_rate == null) r.vat_rate = 21; } },
    accounts: { touch: true },
    daily_records: { touch: true },
    expenses: { defaults: function (r) { if (!r.expense_date) r.expense_date = today(); } },
    settings: {}
  };

  // ---------- RPC simuladas ----------
  var rpc = {
    kpi_recaudacion: function (a, db) {
      var hoy = a.p_hoy || today(), mes0 = hoy.slice(0, 8) + '01';
      var rows = viewTotals(db).filter(function (r) { return (r.status === 'recontado' || r.status === 'facturado') && r.dia >= mes0; });
      return { hoy: r2(rows.filter(function (r) { return r.dia === hoy; }).reduce(function (s, r) { return s + r.total; }, 0)),
        mes: r2(rows.reduce(function (s, r) { return s + r.total; }, 0)), n: rows.length };
    },

    recalc_daily_record: function (a, db, ctx) { return recalcDaily(db, a.p_date, ctx.user); },

    dashboard_resumen: function (a, db) {
      var desde = (a.p_mes || today()).slice(0, 8) + '01';
      var dd = new Date(desde + 'T12:00:00'); dd.setMonth(dd.getMonth() + 1); dd.setDate(0);
      var hasta = ymd(dd), T = today();
      var V = viewTotals(db), lines = db.deposit_lines || [], prods = db.products || [], cli = db.clients || [], locs = db.client_locations || [];
      var liq = V.filter(function (r) { return (r.status === 'recontado' || r.status === 'facturado') && r.dia >= desde && r.dia <= hasta; });
      var liqIds = {}; liq.forEach(function (r) { liqIds[r.id] = 1; });
      var sum = function (arr, f) { return arr.reduce(function (s, x) { return s + f(x); }, 0); };
      var ventas = { liquidaciones: liq.length, neto: r2(sum(liq, function (r) { return r.base; })), bruto: r2(sum(liq, function (r) { return r.total; })),
        iva: r2(sum(liq, function (r) { return r.iva; })), re: r2(sum(liq, function (r) { return r.re; })),
        neto_a: r2(sum(liq, function (r) { return (r.regime || 'A') !== 'B' ? r.base : 0; })), neto_b: r2(sum(liq, function (r) { return (r.regime || 'A') === 'B' ? r.base : 0; })),
        bruto_a: r2(sum(liq, function (r) { return (r.regime || 'A') !== 'B' ? r.total : 0; })) };
      var vend = lines.filter(function (l) { return liqIds[l.deposit_id]; });
      var coste = r2(sum(vend, function (l) { return sold(l) * num(l.unit_cost); }));
      var agg = {};
      vend.forEach(function (l) {
        var k = l.product_code; agg[k] = agg[k] || { ref: k, nombre: (byId(prods, l.product_id) || {}).name || l.product_name, uds: 0, t: isTarjeta(k) };
        agg[k].uds += sold(l);
      });
      var refs = Object.keys(agg).map(function (k) { return agg[k]; }).filter(function (x) { return x.uds > 0; }).sort(function (x, y) { return y.uds - x.uds; });
      var gastosRows = (db.expenses || []).filter(function (e) { return e.expense_date >= desde && e.expense_date <= hasta; });
      var gc = {}; gastosRows.forEach(function (e) { var c = String(e.concept || '').trim().toLowerCase(); c = c.charAt(0).toUpperCase() + c.slice(1); gc[c] = (gc[c] || 0) + num(e.amount); });
      var gastos = r2(sum(gastosRows, function (e) { return num(e.amount); }));
      var tt = {};
      liq.forEach(function (r) {
        var c = byId(cli, r.client_id) || {}, l = r.location_id ? byId(locs, r.location_id) : null;
        var k = (c.commercial_name || c.legal_name || '—') + (l ? ' · ' + l.name : '');
        tt[k] = (tt[k] || 0) + r.total;
      });
      // En la calle (depósitos abiertos)
      var abiertos = (db.deposits || []).filter(function (d) { return d.status === 'abierto'; });
      var abIds = {}; abiertos.forEach(function (d) { abIds[d.id] = d; });
      var calleL = lines.filter(function (l) { return abIds[l.deposit_id]; });
      var pr = {};
      calleL.forEach(function (l) {
        var k = l.product_code; pr[k] = pr[k] || { ref: k, uds: 0, coste: 0, venta: 0 };
        pr[k].uds += num(l.qty_delivered); pr[k].coste += num(l.qty_delivered) * num(l.unit_cost); pr[k].venta += num(l.qty_delivered) * num(l.unit_price);
      });
      var tramos = [['0-30 días', 0, 30], ['31-60 días', 31, 60], ['61-90 días', 61, 90], ['Más de 90 días', 91, 1e9]].map(function (t) {
        var ds = abiertos.filter(function (d) { var age = diffDays(T, d.delivery_date); return age >= t[1] && age <= t[2]; });
        var ids = {}; ds.forEach(function (d) { ids[d.id] = 1; });
        return { tramo: t[0], depositos: ds.length, uds: sum(calleL.filter(function (l) { return ids[l.deposit_id]; }), function (l) { return num(l.qty_delivered); }) };
      });
      // Rotación 12 meses
      var d12 = new Date(hasta + 'T12:00:00'); d12.setFullYear(d12.getFullYear() - 1); var desde12 = ymd(d12);
      var liq12 = {}; V.forEach(function (r) { if ((r.status === 'recontado' || r.status === 'facturado') && r.dia > desde12 && r.dia <= hasta) liq12[r.id] = 1; });
      var rot = {};
      lines.forEach(function (l) {
        if (!liq12[l.deposit_id]) return;
        var k = l.product_code; rot[k] = rot[k] || { ref: k, entregadas: 0, vendidas: 0 };
        rot[k].entregadas += num(l.qty_delivered); rot[k].vendidas += sold(l);
      });
      var pcs = db.pending_collections || [];
      var est = {}; pcs.forEach(function (p) { est[p.status] = est[p.status] || { estado: p.status, n: 0, importe: 0 }; est[p.status].n++; est[p.status].importe += num(p.amount); });
      var met = {}; pcs.filter(function (p) { return p.status === 'pendiente'; }).forEach(function (p) { var m = p.payment_method || 'otro'; met[m] = met[m] || { metodo: m, n: 0, importe: 0 }; met[m].n++; met[m].importe += num(p.amount); });
      var anio = desde.slice(0, 4);
      var activos = cli.filter(function (c) { return c.is_client && c.is_active; });
      var visit = activos.filter(function (c) { return (db.deposits || []).some(function (d) { return d.client_id === c.id && ((d.delivery_date || '').slice(0, 4) === anio || (d.recount_date || '').slice(0, 4) === anio); }); });
      var vals = function (o) { return Object.keys(o).map(function (k) { return o[k]; }); };
      return {
        desde: desde, hasta: hasta, ventas: ventas, coste_vendido: coste,
        tarjetas_vendidas: sum(refs.filter(function (x) { return x.t; }), function (x) { return x.uds; }),
        tarjetas_por_ref: refs.filter(function (x) { return x.t; }).map(function (x) { return { ref: x.ref, uds: x.uds }; }),
        otros_vendidos: refs.filter(function (x) { return !x.t; }).map(function (x) { return { ref: x.ref, nombre: x.nombre, uds: x.uds }; }),
        gastos: gastos,
        gastos_por_concepto: Object.keys(gc).map(function (k) { return { concepto: k, importe: r2(gc[k]) }; }).sort(function (x, y) { return y.importe - x.importe; }),
        ganancia: r2(ventas.neto - coste - gastos),
        top_tiendas: Object.keys(tt).map(function (k) { return { cliente: k, bruto: r2(tt[k]) }; }).sort(function (x, y) { return y.bruto - x.bruto; }).slice(0, 10),
        calle: {
          depositos: abiertos.length, uds: sum(calleL, function (l) { return num(l.qty_delivered); }),
          tarjetas: sum(calleL.filter(function (l) { return isTarjeta(l.product_code); }), function (l) { return num(l.qty_delivered); }),
          coste: r2(sum(calleL, function (l) { return num(l.qty_delivered) * num(l.unit_cost); })),
          venta: r2(sum(calleL, function (l) { return num(l.qty_delivered) * num(l.unit_price); })),
          por_ref: vals(pr).map(function (x) { return { ref: x.ref, uds: x.uds, coste: r2(x.coste), venta: r2(x.venta) }; }).sort(function (x, y) { return y.uds - x.uds; }),
          antiguedad: tramos
        },
        rotacion: vals(rot).map(function (x) { return { ref: x.ref, entregadas: x.entregadas, vendidas: x.vendidas, pct: x.entregadas ? Math.round(x.vendidas * 1000 / x.entregadas) / 10 : 0 }; }),
        cobros_estado: vals(est).map(function (x) { return { estado: x.estado, n: x.n, importe: r2(x.importe) }; }),
        pendiente_por_metodo: vals(met).map(function (x) { return { metodo: x.metodo, n: x.n, importe: r2(x.importe) }; }),
        clientes: { anio: +anio, activos: activos.length, visitados: visit.length }
      };
    },

    sign_visit: function (a, db, ctx) {
      var items = a.p_items || [], name = String(a.p_signer_name || '').trim();
      if (!name) throw E('Falta el nombre de quien firma');
      if (!/^data:image\/png;base64,/.test(a.p_signature_png || '')) throw E('La firma no es válida');
      if (!items.length) throw E('No hay nada que firmar');
      var sigs = db.deposit_signatures || (db.deposit_signatures = []);
      var plan = items.map(function (it) {
        if (it.moment !== 'entrega' && it.moment !== 'recuento') throw E('Momento de firma no válido');
        var d = byId(db.deposits || [], it.deposit_id);
        if (!d) throw E('Depósito no encontrado');
        if (it.moment === 'recuento' && !d.recount_date) throw E('El depósito #' + d.deposit_number + ' aún no está recontado');
        if (sigs.some(function (s) { return s.deposit_id === d.id && s.moment === it.moment && !s.voided_at; }))
          throw E('El depósito #' + d.deposit_number + ' ya tiene firma de ' + it.moment);
        return { d: d, m: it.moment };
      });
      var at = new Date().toISOString();
      var firmas = plan.map(function (p) {
        var snap = snapshot(db, p.d, p.m), h = fakeHash(JSON.stringify(snap)), id = ctx.uuid();
        sigs.push({ id: id, user_id: ctx.user.id, deposit_id: p.d.id, moment: p.m, signer_name: name, signature_png: a.p_signature_png,
          content_snapshot: snap, content_hash: h, device_info: a.p_device_info || null, signed_at: at, voided_at: null, void_reason: null, created_at: at });
        return { signature_id: id, deposit_id: p.d.id, moment: p.m, hash: h };
      });
      return { ok: true, signed_at: at, firmas: firmas };
    },

    void_signature: function (a, db) {
      var reason = String(a.p_reason || '').trim();
      if (!reason) throw E('Indica el motivo de la anulación');
      var s = (db.deposit_signatures || []).filter(function (x) { return x.id === a.p_signature_id && !x.voided_at; })[0];
      if (!s) throw E('Firma no encontrada o ya anulada');
      s.voided_at = new Date().toISOString(); s.void_reason = reason;
      return null;
    },

    // Holded simulado: no sale nada del navegador
    holded_emit_invoice: function (a, db) {
      var d = byId(db.deposits || [], a.p_deposit_id);
      if (!d) throw E('Depósito no encontrado');
      if ((d.regime || 'A') === 'B') throw E('Solo se facturan en Holded los depósitos en régimen A');
      if (d.holded_invoice_id) throw E('Este depósito ya tiene factura en Holded (' + d.holded_invoice_id + ').');
      var c = byId(db.clients || [], d.client_id);
      if (!c) throw E('Cliente del depósito no encontrado');
      if (!c.nif) throw E('El cliente no tiene NIF: complétalo en Contactos antes de facturar.');
      if (c.requires_signature && !(db.deposit_signatures || []).some(function (s) { return s.deposit_id === d.id && s.moment === 'recuento' && !s.voided_at; }))
        throw E('Este cliente exige el recuento firmado antes de facturar.');
      if (!(depositTotals(db, d).base > 0)) throw E('El depósito no tiene unidades vendidas que facturar');
      var n = (db.deposits || []).filter(function (x) { return x.holded_invoice_id; }).length + 1;
      var num_ = 'DEMO-' + new Date().getFullYear() + '-' + ('000' + n).slice(-4);
      var draft = a.p_draft !== false;
      if (!draft) {
        d.holded_invoice_id = 'demo-' + num_; d.holded_invoice_status = 'emitida';
        if (d.status === 'recontado') d.status = 'facturado';
        d.invoice_date = d.invoice_date || d.recount_date || today(); d.updated_at = new Date().toISOString();
      }
      return { ok: true, draft: draft, invoice_id: 'demo-' + num_, invoiceNum: num_ + ' (simulada)', contactId: 'demo-contact' };
    },
    holded_send_invoice: function () { return { ok: true, demo: true }; },
    holded_pay_invoice: function (a, db) {
      var d = byId(db.deposits || [], a.p_deposit_id);
      return { ok: true, skipped: !(d && d.holded_invoice_id), demo: true };
    }
  };

  window.MAGILU_DEMO_HOOKS = { version: 2, seed: seed, tables: tables, views: { v_deposit_totals: viewTotals }, rpc: rpc };
})();
