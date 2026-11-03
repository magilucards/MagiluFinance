# Librerías incluidas en la app

Copias exactas de los paquetes publicados en npm, servidas desde el propio
sitio para que la app funcione sin cobertura y no dependa de un CDN externo.

| Archivo | Paquete npm | Versión | Licencia |
|---|---|---|---|
| `supabase-js-2.100.1.js` | `@supabase/supabase-js` (`dist/umd/supabase.js`) | 2.100.1 | MIT |
| `jspdf-2.5.1.umd.min.js` | `jspdf` (`dist/jspdf.umd.min.js`) | 2.5.1 | MIT (ver `LICENSE-jspdf.txt`) |
| `jspdf-autotable-3.8.2.min.js` | `jspdf-autotable` (`dist/jspdf.plugin.autotable.min.js`) | 3.8.2 | MIT (ver `LICENSE-jspdf-autotable.txt`) |

Supabase JS: MIT License, Copyright (c) 2020 Supabase.

Para actualizar una librería: sustituir el archivo, cambiar el nombre con la
versión nueva en todas las páginas y en `sw.js`, y subir `CACHE_NAME`.
