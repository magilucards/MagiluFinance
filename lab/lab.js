// MagiluFinance LAB · franja de identificación
// Solo interfaz: pinta una franja fija arriba para no confundir nunca el LAB con la app oficial.
// No toca datos, Supabase ni lógica. Se elimina junto con la carpeta lab/ al pasar cambios a main.
(function () {
  'use strict';
  var TEXT = 'LAB · versión de pruebas · los datos son REALES';

  var css = ''
    + ':root{--lab-h:calc(22px + env(safe-area-inset-top, 0px))}'
    + 'html{padding-top:var(--lab-h)!important}'
    + '.app-header{top:var(--lab-h)!important}'
    + '.loading-screen,.modal-overlay,.sign-overlay,.auth-screen{top:var(--lab-h)!important}'
    + '#mf-lab-band{position:fixed;top:0;left:0;right:0;z-index:2147483000;'
    + 'height:var(--lab-h);padding-top:env(safe-area-inset-top, 0px);box-sizing:border-box;'
    + 'display:flex;align-items:center;justify-content:center;gap:8px;'
    + 'background:repeating-linear-gradient(-45deg,#ffc400 0 14px,#ffb000 14px 28px);'
    + 'color:#140c00;font:700 11px/1 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.08em;'
    + 'text-transform:uppercase;pointer-events:none;box-shadow:0 1px 0 rgba(0,0,0,.35)}';
  var st = document.createElement('style');
  st.id = 'mf-lab-style';
  st.textContent = css;
  document.head.appendChild(st);

  // Barra de estado del móvil en amarillo
  function themeColor() {
    var m = document.querySelector('meta[name="theme-color"]');
    if (!m) { m = document.createElement('meta'); m.name = 'theme-color'; document.head.appendChild(m); }
    m.content = '#ffc400';
  }

  function band() {
    if (document.getElementById('mf-lab-band')) return;
    var b = document.createElement('div');
    b.id = 'mf-lab-band';
    b.setAttribute('role', 'note');
    b.textContent = TEXT;
    document.body.insertBefore(b, document.body.firstChild);
    themeColor();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', band);
  else band();
})();
