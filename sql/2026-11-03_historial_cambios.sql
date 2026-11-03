-- =====================================================================
-- MagiluFinance · 2026-11-03 · Historial de cambios (copia en directo)
-- =====================================================================
-- Cada INSERT / UPDATE / DELETE en las tablas con datos de negocio deja
-- una copia en public.audit_log: cómo era la fila antes (old_row) y cómo
-- quedó (new_row). Con eso se puede reconstruir cualquier depósito,
-- cliente, cobro… tal y como estaba en cualquier momento, aunque se haya
-- borrado.
--
-- Seguridad:
--   · Los usuarios solo pueden LEER su propio historial. Nadie puede
--     escribir, cambiar ni borrar el historial desde la app: aunque
--     alguien entrara con tu sesión, no podría tapar lo que ha hecho.
--   · Lo escribe un trigger (security definer, sin permiso de ejecución
--     para nadie: solo lo dispara Postgres).
--
-- No cambia datos ni el comportamiento de la app.
-- =====================================================================

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  changed_at  timestamptz not null default now(),
  table_name  text not null,
  op          text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_id      text,                 -- id de la fila (texto: settings no tiene id)
  user_id     uuid,                 -- dueño de la fila
  actor       uuid,                 -- quién hizo el cambio (null = sistema / SQL)
  old_row     jsonb,                -- antes (UPDATE, DELETE)
  new_row     jsonb                 -- después (INSERT, UPDATE)
);

comment on table public.audit_log is
  'Historial de todos los cambios en las tablas de negocio (copia en directo). Solo lectura para el dueño; lo escribe el trigger audit_capture.';

create index if not exists idx_audit_row  on public.audit_log (table_name, row_id, changed_at desc);
create index if not exists idx_audit_user on public.audit_log (user_id, changed_at desc);

alter table public.audit_log enable row level security;

drop policy if exists audit_read_own on public.audit_log;
create policy audit_read_own on public.audit_log
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.audit_log from public, anon, authenticated;
grant select on public.audit_log to authenticated;


create or replace function public.audit_capture()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_row jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;

  -- Un UPDATE que no cambia nada no deja rastro
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;

  v_row := coalesce(v_new, v_old);
  insert into public.audit_log (table_name, op, row_id, user_id, actor, old_row, new_row)
  values (tg_table_name, tg_op,
          coalesce(v_row ->> 'id', v_row ->> 'user_id'),
          nullif(v_row ->> 'user_id', '')::uuid,
          auth.uid(),
          v_old, v_new);
  return null;   -- trigger AFTER: el valor devuelto no se usa
end;
$$;

revoke all on function public.audit_capture() from public, anon, authenticated;


-- Tablas auditadas (todas las que tienen datos de negocio)
do $$
declare
  t text;
begin
  foreach t in array array[
    'deposits', 'deposit_lines', 'deposit_signatures', 'pending_collections',
    'clients', 'client_locations', 'products',
    'accounts', 'movements', 'daily_records', 'debts', 'fixed_expenses',
    'expenses', 'editable_data', 'settings'
  ] loop
    execute format('drop trigger if exists tr_audit on public.%I', t);
    execute format('create trigger tr_audit after insert or update or delete on public.%I
                    for each row execute function public.audit_capture()', t);
  end loop;
end;
$$;
