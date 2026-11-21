-- =====================================================================
-- MagiluFinance · 2026-11-21
--  1) Cambiar la forma de pago de un depósito ya liquidado/facturado
--     (depósito + cobro de Tesorería + factura de Holded).
--  2) Colaboradores con acceso SOLO a Depósitos (p. ej. Herazo):
--     trabajan sobre los datos del dueño y no ven nada más.
-- =====================================================================
-- Seguridad:
--  · Las políticas del dueño NO se tocan. Se AÑADEN políticas solo para
--    colaboradores activos (tabla app_members, que solo se edita por SQL).
--  · Un colaborador no tiene acceso a: settings, accounts, movements,
--    debts, fixed_expenses, expenses, editable_data, daily_records,
--    audit_log, product_price_history, proveedores (clients no-cliente),
--    cobros que no vienen de un depósito, ni a nada del catálogo.
--  · Las funciones del servidor usan data_owner(): para el dueño es
--    exactamente auth.uid() (comportamiento idéntico al de antes).
--  · audit_log sigue guardando en "actor" quién hizo cada cambio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 2a) Colaboradores
-- ---------------------------------------------------------------------
create table if not exists public.app_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  owner_id   uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'depositos' check (role in ('depositos')),
  nombre     text,
  activo     boolean not null default true,
  created_at timestamptz not null default now(),
  check (user_id <> owner_id)
);
alter table public.app_members enable row level security;
drop policy if exists app_members_read on public.app_members;
create policy app_members_read on public.app_members for select to authenticated
  using (user_id = (select auth.uid()) or owner_id = (select auth.uid()));
-- Sin políticas de escritura: altas y bajas solo desde SQL.

-- Dueño de los datos si quien llama es un colaborador activo (si no, null)
create or replace function public.member_owner()
returns uuid language sql stable security definer set search_path = ''
as $$
  select m.owner_id from public.app_members m
   where m.user_id = (select auth.uid()) and m.activo and m.role = 'depositos'
$$;

-- De quién son los datos con los que se trabaja: el dueño, o el dueño del colaborador
create or replace function public.data_owner()
returns uuid language sql stable security definer set search_path = ''
as $$
  select coalesce(public.member_owner(), (select auth.uid()))
$$;

revoke all on function public.member_owner() from public, anon;
revoke all on function public.data_owner()  from public, anon;
grant execute on function public.member_owner() to authenticated;
grant execute on function public.data_owner()  to authenticated;

-- NIF del emisor para el pie de los PDF (el colaborador no lee settings)
create or replace function public.dep_emisor_nif()
returns text language sql stable security definer set search_path = ''
as $$
  select nullif(btrim(s.company_cif), '') from public.settings s where s.user_id = public.data_owner()
$$;
revoke all on function public.dep_emisor_nif() from public, anon;
grant execute on function public.dep_emisor_nif() to authenticated;

-- ---------------------------------------------------------------------
-- 2b) Políticas SOLO para colaboradores (se suman a las del dueño)
-- ---------------------------------------------------------------------
-- Depósitos: ver, crear y modificar (no borrar)
drop policy if exists member_deposits_select on public.deposits;
drop policy if exists member_deposits_insert on public.deposits;
drop policy if exists member_deposits_update on public.deposits;
create policy member_deposits_select on public.deposits for select to authenticated
  using (user_id = (select public.member_owner()));
create policy member_deposits_insert on public.deposits for insert to authenticated
  with check (user_id = (select public.member_owner()));
create policy member_deposits_update on public.deposits for update to authenticated
  using (user_id = (select public.member_owner()))
  with check (user_id = (select public.member_owner()));

-- Líneas de depósito: todo (editar un depósito abierto borra/añade líneas)
drop policy if exists member_deposit_lines_all on public.deposit_lines;
create policy member_deposit_lines_all on public.deposit_lines for all to authenticated
  using (user_id = (select public.member_owner()))
  with check (user_id = (select public.member_owner()));

-- Clientes: solo los que son clientes (no proveedores). Ver y corregir email/RE.
drop policy if exists member_clients_select on public.clients;
drop policy if exists member_clients_update on public.clients;
create policy member_clients_select on public.clients for select to authenticated
  using (user_id = (select public.member_owner()) and is_client);
create policy member_clients_update on public.clients for update to authenticated
  using (user_id = (select public.member_owner()) and is_client)
  with check (user_id = (select public.member_owner()) and is_client);

-- Tiendas, productos y firmas: solo lectura
drop policy if exists member_client_locations_select on public.client_locations;
create policy member_client_locations_select on public.client_locations for select to authenticated
  using (user_id = (select public.member_owner()));
drop policy if exists member_products_select on public.products;
create policy member_products_select on public.products for select to authenticated
  using (user_id = (select public.member_owner()));
drop policy if exists member_deposit_signatures_select on public.deposit_signatures;
create policy member_deposit_signatures_select on public.deposit_signatures for select to authenticated
  using (user_id = (select public.member_owner()));

-- Cobros: solo los que nacen de un depósito (liquidar crea/actualiza el cobro)
drop policy if exists member_pending_collections_all on public.pending_collections;
create policy member_pending_collections_all on public.pending_collections for all to authenticated
  using (user_id = (select public.member_owner()) and deposit_id is not null)
  with check (user_id = (select public.member_owner()) and deposit_id is not null);

-- ---------------------------------------------------------------------
-- 2c) Funciones de Depósitos: trabajan sobre data_owner() en vez de auth.uid()
--     (para el dueño, data_owner() = auth.uid(): nada cambia)
-- ---------------------------------------------------------------------
do $mig$
declare
  f text; g text;
  procedure_list text[][] := array[
    array['public.holded_emit_invoice(uuid,boolean)', 'user_id = auth.uid()', 'user_id = public.data_owner()'],
    array['public.holded_send_invoice(uuid,text)',    'user_id = auth.uid()', 'user_id = public.data_owner()'],
    array['public.void_signature(uuid,text)',         'user_id = auth.uid()', 'user_id = public.data_owner()'],
    array['public.sign_visit(jsonb,text,text,text)',  'and user_id = auth.uid();', 'and user_id = public.data_owner();'],
    array['public.sign_visit(jsonb,text,text,text)',  '(auth.uid(), d.id, v_moment', '(d.user_id, d.id, v_moment'],
    array['public.recalc_daily_record(date)',         'v_uid    uuid := auth.uid();', 'v_uid    uuid := public.data_owner();']
  ];
  i int;
begin
  for i in 1 .. array_length(procedure_list, 1) loop
    f := pg_get_functiondef(procedure_list[i][1]::regprocedure);
    if position(procedure_list[i][3] in f) > 0 then continue; end if;   -- ya aplicado
    if position(procedure_list[i][2] in f) = 0 then
      raise exception 'Migración: no encuentro "%" en %', procedure_list[i][2], procedure_list[i][1];
    end if;
    g := replace(f, procedure_list[i][2], procedure_list[i][3]);
    execute g;
  end loop;
end $mig$;

-- recalc_daily_record escribe en daily_records del dueño: pasa a SECURITY DEFINER
-- (sigue exigiendo sesión; solo toca filas de data_owner())
alter function public.recalc_daily_record(date) security definer;
revoke all on function public.recalc_daily_record(date) from public, anon;
grant execute on function public.recalc_daily_record(date) to authenticated;

-- ---------------------------------------------------------------------
-- 1) Cambiar la forma de pago (depósito + cobro + Holded)
-- ---------------------------------------------------------------------
create or replace function public._deposit_set_payment(p_owner uuid, p_deposit_id uuid, p_method text)
returns jsonb
language plpgsql security definer
set search_path = 'public', 'extensions', 'vault'
set "http.timeout_msec" = '20000'
as $$
declare
  d record; v_key text; v_pm text; v_resp record; v_now_pm text;
  v_holded text := 'sin_factura'; v_msg text := null; v_cobro text := null;
begin
  if p_owner is null then raise exception 'No autenticado'; end if;
  if p_method is null or p_method not in ('efectivo','tarjeta','transferencia','bizum','pagare','remesa','otro') then
    raise exception 'Forma de pago no válida';
  end if;

  select * into d from deposits where id = p_deposit_id and user_id = p_owner for update;
  if d.id is null then raise exception 'Depósito no encontrado'; end if;
  if d.status not in ('recontado', 'facturado') then
    raise exception 'La forma de pago se elige al liquidar el depósito';
  end if;

  update deposits set payment_method = p_method, updated_at = now() where id = d.id;
  update pending_collections set payment_method = p_method
   where deposit_id = d.id and user_id = p_owner
   returning status into v_cobro;

  -- Holded: cambiar la forma de pago de la factura y comprobar que ha cambiado de verdad
  if d.holded_invoice_id is not null then
    v_pm := case p_method
      when 'efectivo'      then '6a10cbd45deee2e3640a7950'  -- Pago al contado
      when 'bizum'         then '6a10cbd45deee2e3640a7950'  -- (no hay Bizum en Holded) → contado
      when 'transferencia' then '6a10cbd45deee2e3640a794f'  -- Transferencia bancaria
      when 'remesa'        then '6a10e06b4a12b5dcb80436d4'  -- Remesa
      when 'pagare'        then '6a10e0b7ebc18cbd9305531f'  -- Pagaré
      when 'tarjeta'       then '6a10e2b5ef889e37d10652e7'  -- Tarjeta
      else null end;
    if v_pm is null then
      v_holded := 'sin_equivalente';
      v_msg := 'En Holded no hay una forma de pago equivalente a "' || p_method || '": cámbiala allí a mano.';
    else
      begin
        select decrypted_secret into v_key from vault.decrypted_secrets where name = 'HOLDED_API_KEY' limit 1;
        if v_key is null then raise exception 'HOLDED_API_KEY no está en Vault'; end if;
        select r.status, r.content into v_resp from extensions.http((
          'PUT', 'https://api.holded.com/api/invoicing/v1/documents/invoice/' || d.holded_invoice_id,
          array[extensions.http_header('key', v_key)],
          'application/json', jsonb_build_object('paymentMethodId', v_pm)::text)::extensions.http_request) r;
        if v_resp.status <> 200 then
          raise exception 'Holded devolvió status %: %', v_resp.status, left(coalesce(v_resp.content, ''), 200);
        end if;
        select r.status, r.content into v_resp from extensions.http((
          'GET', 'https://api.holded.com/api/invoicing/v1/documents/invoice/' || d.holded_invoice_id,
          array[extensions.http_header('key', v_key)], null, null)::extensions.http_request) r;
        if v_resp.status = 200 then v_now_pm := (v_resp.content::jsonb)->>'paymentMethodId'; end if;
        if v_now_pm = v_pm then
          v_holded := 'actualizada';
        else
          v_holded := 'no_cambiada';
          v_msg := 'Holded no ha aplicado el cambio: cámbialo allí a mano.';
        end if;
      exception when others then
        v_holded := 'error';
        v_msg := 'No se pudo cambiar en Holded (' || left(sqlerrm, 200) || '): cámbialo allí a mano.';
      end;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'payment_method', p_method,
    'cobro_status', v_cobro, 'holded', v_holded, 'holded_msg', v_msg);
end $$;
revoke all on function public._deposit_set_payment(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.deposit_set_payment(p_deposit_id uuid, p_method text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;
  return public._deposit_set_payment(public.data_owner(), p_deposit_id, p_method);
end $$;
revoke all on function public.deposit_set_payment(uuid, text) from public, anon;
grant execute on function public.deposit_set_payment(uuid, text) to authenticated;

-- =====================================================================
-- Alta de un colaborador (después de crear su usuario en Supabase Auth):
--   insert into public.app_members (user_id, owner_id, nombre)
--   select u.id, '<uuid del dueño>', 'Herazo' from auth.users u where u.email = 'herazo@magilucards.com';
--   update auth.users set raw_app_meta_data = raw_app_meta_data
--     || jsonb_build_object('mf_role', 'depositos', 'mf_owner', '<uuid del dueño>')
--    where email = 'herazo@magilucards.com';
-- Baja: update public.app_members set activo = false where user_id = ...;
--   (sin acceso al instante, aunque siga con la sesión abierta)
-- =====================================================================
