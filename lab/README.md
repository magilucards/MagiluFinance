# Magilu · LAB (modo demo)

Rama `ui-lab`: laboratorio de interfaz. **No es la app oficial y no está conectada a nada real.**

## Desconexión
- Las páginas del LAB no cargan el SDK de Supabase: cargan `lab/demo-data.js` + `lab/demo-backend.js`,
  un cliente falso con la misma API que usa la app (select/insert/update/delete, filtros, rpc, auth).
- Los datos son ficticios y viven en el navegador (localStorage). Cada dispositivo tiene los suyos.
- Holded solo se usaba a través de funciones de Supabase (`holded_emit_invoice`, `holded_send_invoice`,
  `holded_pay_invoice`): aquí se simulan y no sale nada del dispositivo.
- Candado extra: la CSP de cada página tiene `connect-src 'self'`, así que el navegador bloquea
  cualquier conexión a Supabase/Holded aunque quedara algún hueco.
- Login: cualquier email y contraseña. Tocar la franja superior reinicia los datos de prueba.

## Identidad
- `lab.js`: franja fija "LAB · modo demo", paleta Magilu (blanco y rosas) y avisos marcados como demo.
- `manifest.json` + iconos: PWA "Magilu" con el logo de Magilu.

## Pasar cambios a la oficial
Se lleva a `main` solo el cambio de diseño concreto (cherry-pick), nunca la carpeta `lab/`,
el cambio de CSP ni la sustitución del SDK.
