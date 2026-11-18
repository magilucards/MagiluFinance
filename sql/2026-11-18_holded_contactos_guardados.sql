-- =====================================================================
-- MagiluFinance · 2026-11-18 · Holded: contactos guardados
-- =====================================================================
-- «Facturar en Holded» pedía a Holded la lista ENTERA de contactos (374) en
-- cada factura para encontrar al cliente por su NIF. Holded ha pasado a
-- tardar 6, 12 y hasta 32 segundos en darla, y las facturas fallaban
-- («sin conexión» en la app). Ahora:
--   · holded_contactos guarda NIF → contacto de Holded.
--   · La factura busca ahí primero (sin esperar a Holded). Solo si el
--     cliente no está (uno nuevo) pide la lista a Holded, la guarda entera y
--     sigue. Si tampoco está en Holded, el aviso de siempre: «créalo antes
--     de facturar».
-- Lo demás de holded_emit_invoice no cambia: se sustituye solo el trozo de
-- buscar el contacto, y si la función no es la esperada, no se toca nada.
-- =====================================================================

select extensions.http_reset_curlopt();   -- carga la extensión de llamadas web: así se puede fijar http.timeout_msec

-- 1) NIF → contacto de Holded (solo lo usan las funciones de Holded)
create table if not exists public.holded_contactos (
  user_id uuid not null references auth.users(id) on delete cascade,
  nif text not null,
  contact_id text not null,
  nombre text,
  updated_at timestamptz not null default now(),
  primary key (user_id, nif)
);
alter table public.holded_contactos enable row level security;
revoke all on public.holded_contactos from anon, authenticated;

-- 2) Pide a Holded la lista entera (lenta) y la guarda; devuelve cuántos NIF ha guardado
create or replace function public.holded_contactos_refrescar(p_user uuid, p_key text) returns integer
language plpgsql security definer set search_path to 'public', 'extensions', 'vault' set http.timeout_msec = 50000 as $$
declare v_resp record; v_contacts jsonb; n integer;
begin
  select r.status, r.content into v_resp from extensions.http((
    'GET','https://api.holded.com/api/invoicing/v1/contacts',
    array[extensions.http_header('key', p_key)], null, null)::extensions.http_request) r;
  if v_resp.status <> 200 then raise exception 'Holded devolvió status % al listar contactos', v_resp.status; end if;
  begin v_contacts := v_resp.content::jsonb;
  exception when others then raise exception 'Holded devolvió una respuesta no válida al listar contactos'; end;
  if jsonb_typeof(v_contacts) <> 'array' then raise exception 'Holded devolvió una respuesta no válida al listar contactos'; end if;
  -- Si dos contactos tienen el mismo NIF, el primero de la lista (como hacía la factura)
  insert into public.holded_contactos (user_id, nif, contact_id, nombre, updated_at)
  select distinct on (upper(trim(e.value->>'code'))) p_user, upper(trim(e.value->>'code')), e.value->>'id', e.value->>'name', now()
    from jsonb_array_elements(v_contacts) with ordinality e
   where coalesce(trim(e.value->>'code'), '') <> '' and coalesce(e.value->>'id', '') <> ''
   order by upper(trim(e.value->>'code')), e.ordinality
  on conflict (user_id, nif) do update set contact_id = excluded.contact_id, nombre = excluded.nombre, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.holded_contactos_refrescar(uuid, text) from public, anon, authenticated;

-- 3) La factura busca primero el contacto guardado
do $do$
declare
  v_def text := pg_get_functiondef('public.holded_emit_invoice(uuid,boolean)'::regprocedure);
  v_viejo text := $viejo$  select r.status, r.content into v_resp from extensions.http((
    'GET','https://api.holded.com/api/invoicing/v1/contacts',
    array[extensions.http_header('key', v_key)], null, null)::extensions.http_request) r;
  if v_resp.status <> 200 then raise exception 'Holded devolvió status % al listar contactos', v_resp.status; end if;
  begin v_contacts := v_resp.content::jsonb;
  exception when others then raise exception 'Holded devolvió una respuesta no válida al listar contactos'; end;
  select (elem->>'id') into v_contact_id
  from jsonb_array_elements(v_contacts) elem
  where upper(trim(elem->>'code')) = upper(trim(c.nif)) limit 1;
  if v_contact_id is null then
    raise exception 'El cliente % (NIF %) no existe en Holded; créalo antes de facturar.',
      coalesce(c.commercial_name, c.legal_name), c.nif;
  end if;
$viejo$;
  v_nuevo text := $nuevo$  -- Contacto de Holded por el NIF: el guardado; si no está (cliente nuevo), se pide la lista a Holded y se guarda
  select hc.contact_id into v_contact_id from public.holded_contactos hc
   where hc.user_id = d.user_id and hc.nif = upper(trim(c.nif));
  if v_contact_id is null then
    perform public.holded_contactos_refrescar(d.user_id, v_key);
    select hc.contact_id into v_contact_id from public.holded_contactos hc
     where hc.user_id = d.user_id and hc.nif = upper(trim(c.nif));
  end if;
  if v_contact_id is null then
    raise exception 'El cliente % (NIF %) no existe en Holded; créalo antes de facturar.',
      coalesce(c.commercial_name, c.legal_name), c.nif;
  end if;
$nuevo$;
begin
  if (length(v_def) - length(replace(v_def, v_viejo, ''))) <> length(v_viejo) then
    raise exception 'holded_emit_invoice no es la que se esperaba: no se toca nada';
  end if;
  execute replace(v_def, v_viejo, v_nuevo);
end $do$;

-- 4) Para el caso lento (cliente nuevo: lista entera + factura), las peticiones con sesión pueden durar hasta 60 s
alter role authenticated set statement_timeout = '60s';
notify pgrst, 'reload config';
