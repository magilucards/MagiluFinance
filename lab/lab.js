// Magilu LAB · identidad y tema
// Solo interfaz: franja fija "LAB · MODO DEMO" y paleta Magilu (blanco + rosas).
// No toca datos ni lógica. Se elimina junto con la carpeta lab/ al pasar cambios a main.
(function () {
  'use strict';
  var TEXT = 'LAB · MODO DEMO · datos de prueba · sin Supabase ni Holded';

  // Paleta Magilu: rosa del logo (#FD0F9D) y variantes legibles sobre blanco.
  // "html:root" gana a ":root" de cada página sin tocar su CSS.
  var theme = 'html:root{color-scheme:light;'
    + '--bg:#fff6fa;--bg-elev:#ffffff;--bg-card:#ffffff;'
    + '--border:#f7d6e7;--border-strong:#efb4d3;'
    + '--text:#3a1029;--text-dim:#865670;--text-faint:#b48aa1;'
    + '--primary:#e0127f;--primary-dim:#f0469f;--primary-bright:#b30c66;'
    + '--accent:#fbd3e6;--accent-bright:#f29cc8;'
    + '--amber:#b86e00;--amber-bright:#9a5b00;'
    + '--red:#cf2e3b;--red-bright:#ad1f2c;'
    + '--green:#178a5c;--green-bright:#11704a;'
    + '--s-other:#b48aa1;--track:#fbe3ef}'
    + 'html,body{background:var(--bg)}'
    + '::selection{background:#fbd3e6;color:#3a1029}'
    // Botones de privacidad (privacy.js) adaptados al tema
    + '.mf-privacy-btn{border-color:var(--border-strong)!important;color:var(--text-dim)!important}';

  var band = ':root{--lab-h:calc(22px + env(safe-area-inset-top, 0px))}'
    + 'html{padding-top:var(--lab-h)!important}'
    + '.app-header{top:var(--lab-h)!important}'
    + '.loading-screen,.modal-overlay,.sign-overlay,.auth-screen{top:var(--lab-h)!important}'
    + '#mf-lab-band{position:fixed;top:0;left:0;right:0;z-index:2147483000;'
    + 'height:var(--lab-h);padding-top:env(safe-area-inset-top, 0px);box-sizing:border-box;'
    + 'display:flex;align-items:center;justify-content:center;gap:8px;'
    + 'background:repeating-linear-gradient(-45deg,#3a1029 0 14px,#4d1538 14px 28px);'
    + 'color:#fff;font:700 10px/1 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.08em;'
    + 'text-transform:uppercase;white-space:nowrap;overflow:hidden;box-shadow:0 1px 0 rgba(0,0,0,.25);cursor:pointer}'
    + '#mf-lab-band b{color:#ff7ac0}'
    + '@media (max-width:560px){#mf-lab-band .mf-lab-long{display:none}}';

  var st = document.createElement('style');
  st.id = 'mf-lab-style';
  st.textContent = theme + band;
  document.head.appendChild(st);

  function themeColor() {
    var m = document.querySelector('meta[name="theme-color"]');
    if (!m) { m = document.createElement('meta'); m.name = 'theme-color'; document.head.appendChild(m); }
    m.content = '#3a1029';
  }

  function mount() {
    if (document.getElementById('mf-lab-band')) return;
    var b = document.createElement('div');
    b.id = 'mf-lab-band';
    b.setAttribute('role', 'note');
    b.title = 'Toca para reiniciar los datos de prueba';
    var t = document.createElement('b'); t.textContent = 'LAB';
    var long = document.createElement('span'); long.className = 'mf-lab-long'; long.textContent = ' · sin Supabase ni Holded';
    b.appendChild(t);
    b.appendChild(document.createTextNode(' · modo demo · datos de prueba'));
    b.appendChild(long);
    // Tocar la franja → reiniciar datos de demo (solo en este navegador)
    b.addEventListener('click', function () {
      if (!window.MAGILU_DEMO) return;
      if (confirm('¿Reiniciar los datos de prueba de este dispositivo?\n\nSolo afecta al LAB en este navegador.')) {
        window.MAGILU_DEMO.reset();
        location.reload();
      }
    });
    document.body.insertBefore(b, document.body.firstChild);
    themeColor();
  }

  // Los avisos de la app hablan de Holded "real": en el LAB se dejan claros como simulación
  var PREFIX = '🧪 MODO DEMO · nada sale del dispositivo (ni Supabase ni Holded)\n\n';
  var _confirm = window.confirm.bind(window), _alert = window.alert.bind(window);
  window.confirm = function (m) { return _confirm(PREFIX + (m == null ? '' : m)); };
  window.alert = function (m) { return _alert(PREFIX + (m == null ? '' : m)); };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
  else mount();
})();
