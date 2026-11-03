// Magilu Finance · Copia local en el iPhone (IndexedDB)
// Cada vez que se guarda un depósito queda una copia en el propio dispositivo:
// la última versión de cada depósito con sus líneas y un registro de los guardados.
// Es independiente de Supabase y de GitHub. Se puede exportar desde Inicio.
(function () {
  'use strict';
  var DB_NAME = 'magilu-local';
  var DB_VER = 1;
  var LOG_MAX = 2000;           // guardados que se conservan en el registro
  var dbPromise = null;

  function open() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise(function (resolve, reject) {
      if (!window.indexedDB) { reject(new Error('Sin IndexedDB')); return; }
      var r = indexedDB.open(DB_NAME, DB_VER);
      r.onupgradeneeded = function () {
        var db = r.result;
        if (!db.objectStoreNames.contains('deposits')) db.createObjectStore('deposits', { keyPath: 'id' });
        if (!db.objectStoreNames.contains('log')) db.createObjectStore('log', { keyPath: 'seq', autoIncrement: true });
      };
      r.onsuccess = function () { resolve(r.result); };
      r.onerror = function () { reject(r.error); };
    });
    // Pide al navegador que no borre estos datos por falta de espacio
    try { if (navigator.storage && navigator.storage.persist) navigator.storage.persist(); } catch (e) { /* opcional */ }
    return dbPromise;
  }

  function tx(stores, mode, fn) {
    return open().then(function (db) {
      return new Promise(function (resolve, reject) {
        var t = db.transaction(stores, mode);
        var out = fn(t);
        t.oncomplete = function () { resolve(out && out.result !== undefined ? out.result : out); };
        t.onerror = function () { reject(t.error); };
        t.onabort = function () { reject(t.error); };
      });
    });
  }

  function getAll(store) {
    return tx([store], 'readonly', function (t) { return t.objectStore(store).getAll(); });
  }

  // Guarda la versión actual de un depósito (deleted = true si se ha borrado)
  function saveDeposit(deposit, lines, deleted) {
    if (!deposit || !deposit.id) return Promise.resolve();
    var rec = {
      id: deposit.id,
      saved_at: new Date().toISOString(),
      deleted: !!deleted,
      deposit: deposit,
      lines: lines || []
    };
    return tx(['deposits', 'log'], 'readwrite', function (t) {
      t.objectStore('deposits').put(rec);
      t.objectStore('log').add({ at: rec.saved_at, id: rec.id, deleted: rec.deleted,
        deposit_number: deposit.deposit_number, status: deposit.status });
      // Recorta el registro a los últimos LOG_MAX guardados
      var logStore = t.objectStore('log');
      var cnt = logStore.count();
      cnt.onsuccess = function () {
        var extra = cnt.result - LOG_MAX;
        if (extra <= 0) return;
        var cur = logStore.openCursor();
        cur.onsuccess = function () {
          var c = cur.result;
          if (c && extra-- > 0) { c.delete(); c.continue(); }
        };
      };
    });
  }

  // Todo lo guardado en el dispositivo, para exportarlo
  function exportAll() {
    return Promise.all([getAll('deposits'), getAll('log')]).then(function (r) {
      return { deposits: r[0], log: r[1] };
    });
  }

  function count() {
    return tx(['deposits'], 'readonly', function (t) { return t.objectStore('deposits').count(); });
  }

  window.MFLocal = { saveDeposit: saveDeposit, exportAll: exportAll, count: count };
})();
