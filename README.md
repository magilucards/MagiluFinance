# Magilu Finance

Panel financiero personal — gestión de cuentas, pólizas, movimientos y liquidez.

## Características

- Dashboard de liquidez en tiempo real (KPIs con cálculo automático).
- Gestión de cuentas bancarias, pólizas y cuentas separadas (Hacienda, colchón).
- Registro de movimientos (ingresos, gastos, traspasos, pagos Hacienda, amortizaciones).
- Alertas inteligentes (liquidez baja, pagos trimestrales próximos, pólizas excedidas).
- PWA instalable, funciona offline para consultar.
- Sincronización en la nube vía Supabase (acceso desde cualquier dispositivo).

## Stack técnico

- **Frontend**: HTML/CSS/JS vanilla. Fraunces + JetBrains Mono + Inter Tight.
- **Backend**: [Supabase](https://supabase.com) (PostgreSQL + Auth + Row Level Security).
- **Hosting**: GitHub Pages.
- **PWA**: service worker con cache-first para shell, network-only para datos Supabase.

## Seguridad

Esta aplicación implementa múltiples capas:

**Backend (Supabase)**:
- Row Level Security (RLS): cada usuario solo ve sus propios datos.
- Políticas optimizadas con subquery cache.
- Trigger `SECURITY DEFINER` con `search_path` fijo (sin role mutable).
- EXECUTE revocado de roles públicos en funciones sensibles.
- 0 advisors de seguridad activos.

**Frontend**:
- Content-Security-Policy estricta (solo CDN whitelisted, sin eval).
- Subresource Integrity (SRI) en el SDK de Supabase.
- X-Content-Type-Options, Referrer-Policy, robots noindex.
- Validación de contraseña fuerte (8+ caracteres, mayúscula, minúscula, número).
- Sanitización de inputs con `sanitizeUserInput()`.
- Validación de rango en todos los importes monetarios.
- Renderizado vía DOM API (no innerHTML con templates) para prevenir XSS.
- Mensajes de error filtrados (no exponen detalles internos).
- `detectSessionInUrl: false` (no OAuth, sin tokens en URL).
- `onAuthStateChange` para sync de logout entre pestañas.
- ESC cierra modales.

**Privacidad**:
- Código fuente público pero sin datos personales.
- Datos financieros solo en Supabase con RLS.
- No analytics, no tracking, no terceros más allá del CDN del SDK.

## Despliegue

Requiere:
1. Repo público en GitHub.
2. GitHub Pages activado (branch `main`, root).
3. Site URL configurada en Supabase Auth.

Ver `INSTRUCCIONES_DESPLIEGUE.md` para los pasos completos.

## Licencia

Uso personal de Tomás Santofímia.
