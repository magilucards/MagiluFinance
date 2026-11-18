-- =====================================================================
-- MagiluFinance · 2026-11-18 · Holded: más tiempo para facturar
-- =====================================================================
-- «Facturar en Holded» fallaba siempre con «sin conexión» aunque hubiera
-- internet. Lo que pasaba:
--   · holded_emit_invoice pide a Holded la lista de contactos para buscar al
--     cliente por su NIF. Con 374 contactos Holded tarda 6-7 segundos.
--   · El servidor cortaba cada llamada a Holded a los 5 s («Operation timed
--     out after 5002 milliseconds»), y la app, al ver «timed out» en el
--     error, lo enseñaba como «sin conexión».
--   · Además, cada petición con sesión se cortaba a los 8 s, y la lista de
--     contactos más la factura pasan de eso.
-- Arreglo:
--   · Cada llamada a Holded de estas funciones puede durar hasta 20 s.
--   · Las peticiones con sesión (MagiluFinance y el panel del catálogo)
--     pueden durar hasta 45 s (antes 8 s). La app ya espera hasta 90 s.
-- No cambia nada de lo que se factura: solo cuánto se espera a Holded.
-- =====================================================================

alter function public.holded_emit_invoice(uuid, boolean) set http.timeout_msec = 20000;
alter function public.holded_pay_invoice(uuid, date) set http.timeout_msec = 20000;
alter function public.holded_send_invoice(uuid, text) set http.timeout_msec = 20000;
alter function public.holded_ping() set http.timeout_msec = 20000;

alter role authenticated set statement_timeout = '45s';
notify pgrst, 'reload config';
