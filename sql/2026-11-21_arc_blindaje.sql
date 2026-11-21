-- =====================================================================
-- 2026-11-21 · ARC Reformas: blindaje (aplicado en Supabase)
-- =====================================================================
-- Carpeta arc-reformas-form (donde está la app): nadie sin sesión puede
-- subir, cambiar ni borrar archivos. Abrir la app (leer) sigue igual.
drop policy if exists allow_anon_insert_arc_form on storage.objects;
drop policy if exists allow_anon_update_arc_form on storage.objects;
drop policy if exists allow_anon_delete_arc_form on storage.objects;

-- PIN de acceso: registro de fallos para frenar a quien intente adivinarlo
-- (la función arc-reformas-api corta a los 10 fallos por IP o 100 en total en 15 min).
create table if not exists public.arc_login_fallos (
  id bigint generated always as identity primary key,
  ip text not null default '?',
  created_at timestamptz not null default now()
);
create index if not exists arc_login_fallos_created on public.arc_login_fallos (created_at);
create index if not exists arc_login_fallos_ip on public.arc_login_fallos (ip, created_at);
alter table public.arc_login_fallos enable row level security;

-- Funciones (desplegadas aparte, el código no está en este repositorio):
--  · arc-reformas-api v22: límite de intentos del PIN.
--  · arc-pwa-upload v3: solo sube con la cabecera x-arc-upload-key = secreto
--    ARC_UPLOAD_KEY (Supabase → Edge Functions → Secrets). Sin secreto, no sube nada.
--    Para publicar una versión nueva: crear el secreto, o subir el archivo a mano
--    en Storage → arc-reformas-form.
