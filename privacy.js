// Magilu Finance · Modo oculto
// Cambia las cifras de dinero por asteriscos para poder enseñar la app sin mostrar números.
// Se recuerda por dispositivo (localStorage). Solo afecta a lo que se ve en pantalla:
// nunca a los PDF, a Holded ni a los datos guardados.
(function () {
  'use strict';
  var KEY = 'mf_privacy';
  var on = false;
  try { on = localStorage.getItem(KEY) === '1'; } catch (e) { /* sin almacenamiento: modo normal */ }

  window.MF_PRIVACY = on;
  document.documentElement.classList.toggle('privacy', on);

  // Devuelve el texto tal cual o, en modo oculto, asteriscos
  window.mfMask = function (text) { return on ? '****' : text; };
  window.mfMaskMoney = function (text) { return on ? '**** €' : text; };

  function toggle() {
    try { localStorage.setItem(KEY, on ? '0' : '1'); } catch (e) { return; }
    location.reload();
  }

  // Botón 👁 en el elemento marcado con data-privacy-slot
  document.addEventListener('DOMContentLoaded', function () {
    var slot = document.querySelector('[data-privacy-slot]');
    if (!slot) return;
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'mf-privacy-btn' + (on ? ' active' : '');
    b.title = on ? 'Mostrar cifras' : 'Ocultar cifras (modo oculto)';
    b.setAttribute('aria-label', b.title);
    b.textContent = on ? '🙈' : '👁';
    b.addEventListener('click', toggle);
    slot.appendChild(b);
  });

  // Estilo del botón (igual en todas las pantallas)
  var css = '.mf-privacy-btn{background:transparent;border:1px solid #2c3a5c;color:#8a9bb2;border-radius:6px;'
    + 'min-width:36px;height:32px;padding:0 8px;font-size:15px;line-height:1;cursor:pointer}'
    + '.mf-privacy-btn.active{border-color:#e8b85a;background:rgba(212,160,74,.12)}';
  var st = document.createElement('style');
  st.textContent = css;
  document.head.appendChild(st);
})();
