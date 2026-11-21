-- =====================================================================
-- MagiluFinance · 2026-11-21 · Espacios (TOMÁS / JP) + cambiar forma de pago
-- =====================================================================
-- ESPACIOS
--  · Cada usuario tiene su espacio: sus filas (user_id = su id). Igual que hoy.
--  · app_members da acceso a espacios ajenos:
--      rol 'completo'  → todo el espacio (Tomás en el de JP)
--      rol 'depositos' → solo Depósitos (JP en el de Tomás)
--  · La app manda la cabecera  x-mf-space: <id del espacio elegido>.
--    current_space() la valida contra app_members; sin cabecera (o la tuya)
--    es tu propio espacio  →  para Tomás todo funciona exactamente igual.
--    Cabecera de un espacio sin permiso → null → no se ve ni se escribe nada.
--  · Las políticas pasan de  user_id = auth.uid()  a  user_id = current_space()
--    (+ qué tablas permite cada rol). Un trigger pone user_id = current_space()
--    al insertar, así lo creado en el espacio de Tomás es de Tomás.
--  · Las funciones del servidor usan current_space() (Depósitos) o
--    space_full_id() (Tesorería, Inicio…: exige rol completo o propio).
--  · audit_log sigue guardando en "actor" la persona real (auth.uid()).
-- FORMA DE PAGO
--  · deposit_set_payment(): depósito + cobro + factura de Holded, y comprueba
--    en Holded que el cambio se ha aplicado de verdad.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Espacios y accesos
-- ---------------------------------------------------------------------
create table if not exists public.app_spaces (
  owner_id   uuid primary key references auth.users(id) on delete cascade,
  nombre     text not null,
  orden      integer not null default 99,
  created_at timestamptz not null default now()
);
alter table public.app_spaces enable row level security;

create table if not exists public.app_members (
  user_id    uuid not null references auth.users(id) on delete cascade,  -- quien entra
  owner_id   uuid not null references auth.users(id) on delete cascade,  -- espacio al que entra
  role       text not null check (role in ('depositos', 'completo')),
  activo     boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (user_id, owner_id),
  check (user_id <> owner_id)
);
alter table public.app_members enable row level security;
-- Sin políticas: se leen con mf_spaces() y se editan solo por SQL.

-- Espacio activo de la petición (cabecera x-mf-space validada)
create or replace function public.current_space()
returns uuid language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := auth.uid(); v_h text; v_s uuid;
begin
  if v_uid is null then return null; end if;
  begin v_h := current_setting('request.headers', true)::json->>'x-mf-space';
  exception when others then v_h := null; end;
  if v_h is null or v_h = '' then return v_uid; end if;
  if v_h !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  v_s := v_h::uuid;
  if v_s = v_uid then return v_uid; end if;
  if exists (select 1 from public.app_members m where m.user_id = v_uid and m.owner_id = v_s and m.activo) then
    return v_s;
  end if;
  return null;
end $$;

-- Rol en el espacio activo: 'propio' | 'completo' | 'depositos' | null
create or replace function public.space_role()
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when auth.uid() is null or public.current_space() is null then null
    when public.current_space() = auth.uid() then 'propio'
    else (select m.role from public.app_members m
           where m.user_id = auth.uid() and m.owner_id = public.current_space() and m.activo)
  end
$$;

create or replace function public.space_full()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(public.space_role() in ('propio', 'completo'), false) $$;

-- Para funciones de Tesorería, Inicio, Plan…: el espacio, solo con acceso completo
create or replace function public.space_full_id()
returns uuid language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null then return null; end if;
  if not public.space_full() then raise exception 'Sin permiso en este espacio' using errcode = '42501'; end if;
  return public.current_space();
end $$;

-- Espacios a los que puede entrar quien llama (para el selector)
create or replace function public.mf_spaces()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x.j order by x.orden, x.nombre), '[]'::jsonb) from (
    select jsonb_build_object('id', u.id, 'nombre', coalesce(s.nombre, split_part(u.email, '@', 1)),
                              'rol', 'propio', 'propio', true) j,
           coalesce(s.orden, 99) orden, coalesce(s.nombre, u.email) nombre
      from auth.users u left join public.app_spaces s on s.owner_id = u.id
     where u.id = auth.uid()
    union all
    select jsonb_build_object('id', m.owner_id, 'nombre', coalesce(s.nombre, 'Espacio'),
                              'rol', m.role, 'propio', false),
           coalesce(s.orden, 99), coalesce(s.nombre, '')
      from public.app_members m left join public.app_spaces s on s.owner_id = m.owner_id
     where m.user_id = auth.uid() and m.activo
  ) x
$$;

-- NIF del emisor para el pie de los PDF (con rol Depósitos no se lee settings)
create or replace function public.dep_emisor_nif()
returns text language sql stable security definer set search_path = ''
as $$ select nullif(btrim(s.company_cif), '') from public.settings s where s.user_id = public.current_space() $$;

do $g$
declare f text;
begin
  foreach f in array array['public.current_space()', 'public.space_role()', 'public.space_full()',
                           'public.space_full_id()', 'public.mf_spaces()', 'public.dep_emisor_nif()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $g$;

-- ---------------------------------------------------------------------
-- 2) user_id de lo que se crea = el espacio activo
-- ---------------------------------------------------------------------
create or replace function public.set_space_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_s uuid := public.current_space();
begin
  if v_s is not null then new.user_id := v_s; end if;   -- sin sesión (SQL de administración): no se toca
  return new;
end $$;
revoke all on function public.set_space_user() from public, anon, authenticated;

do $t$
declare t text;
begin
  foreach t in array array['accounts','client_locations','clients','daily_records','debts','deposit_lines',
                           'deposit_signatures','deposits','editable_data','expenses','fixed_expenses',
                           'movements','pending_collections','product_price_history','products','settings'] loop
    execute format('drop trigger if exists tr_space_user on public.%I', t);
    execute format('create trigger tr_space_user before insert on public.%I for each row execute function public.set_space_user()', t);
  end loop;
end $t$;

-- ---------------------------------------------------------------------
-- 3) Políticas: del dueño (auth.uid) a espacio (current_space)
-- ---------------------------------------------------------------------
drop policy if exists own_accounts          on public.accounts;
drop policy if exists audit_read_own        on public.audit_log;
drop policy if exists own_client_locations  on public.client_locations;
drop policy if exists own_clients           on public.clients;
drop policy if exists own_daily             on public.daily_records;
drop policy if exists own_debts             on public.debts;
drop policy if exists deposit_lines_delete_own on public.deposit_lines;
drop policy if exists deposit_lines_insert_own on public.deposit_lines;
drop policy if exists deposit_lines_select_own on public.deposit_lines;
drop policy if exists deposit_lines_update_own on public.deposit_lines;
drop policy if exists deposit_signatures_select_own on public.deposit_signatures;
drop policy if exists deposits_delete_own   on public.deposits;
drop policy if exists deposits_insert_own   on public.deposits;
drop policy if exists deposits_select_own   on public.deposits;
drop policy if exists deposits_update_own   on public.deposits;
drop policy if exists own_editable          on public.editable_data;
drop policy if exists own_expenses          on public.expenses;
drop policy if exists own_expenses          on public.fixed_expenses;
drop policy if exists own_movements         on public.movements;
drop policy if exists own_pending           on public.pending_collections;
drop policy if exists own_pph               on public.product_price_history;
drop policy if exists own_products          on public.products;
drop policy if exists own_settings          on public.settings;

-- 3a) Tablas que SOLO ve quien tiene el espacio completo
do $p$
declare t text;
begin
  foreach t in array array['accounts','daily_records','debts','editable_data','expenses','fixed_expenses',
                           'movements','product_price_history','settings'] loop
    execute format('drop policy if exists space_all on public.%I', t);
    execute format('create policy space_all on public.%I for all to authenticated
      using (user_id = (select public.current_space()) and (select public.space_full()))
      with check (user_id = (select public.current_space()) and (select public.space_full()))', t);
  end loop;
end $p$;
drop policy if exists space_select on public.audit_log;
create policy space_select on public.audit_log for select to authenticated
  using (user_id = (select public.current_space()) and (select public.space_full()));

-- 3b) Depósitos: cualquier rol del espacio; borrar depósitos solo con acceso completo
drop policy if exists space_select on public.deposits;
drop policy if exists space_insert on public.deposits;
drop policy if exists space_update on public.deposits;
drop policy if exists space_delete on public.deposits;
create policy space_select on public.deposits for select to authenticated
  using (user_id = (select public.current_space()));
create policy space_insert on public.deposits for insert to authenticated
  with check (user_id = (select public.current_space()));
create policy space_update on public.deposits for update to authenticated
  using (user_id = (select public.current_space()))
  with check (user_id = (select public.current_space()));
create policy space_delete on public.deposits for delete to authenticated
  using (user_id = (select public.current_space()) and (select public.space_full()));

drop policy if exists space_all on public.deposit_lines;
create policy space_all on public.deposit_lines for all to authenticated
  using (user_id = (select public.current_space()))
  with check (user_id = (select public.current_space()));

drop policy if exists space_select on public.deposit_signatures;
create policy space_select on public.deposit_signatures for select to authenticated
  using (user_id = (select public.current_space()));

-- Clientes: con rol Depósitos solo los que son clientes (no proveedores); ver y corregir email/RE
drop policy if exists space_select on public.clients;
drop policy if exists space_update on public.clients;
drop policy if exists space_insert on public.clients;
drop policy if exists space_delete on public.clients;
create policy space_select on public.clients for select to authenticated
  using (user_id = (select public.current_space()) and ((select public.space_full()) or is_client));
create policy space_update on public.clients for update to authenticated
  using (user_id = (select public.current_space()) and ((select public.space_full()) or is_client))
  with check (user_id = (select public.current_space()) and ((select public.space_full()) or is_client));
create policy space_insert on public.clients for insert to authenticated
  with check (user_id = (select public.current_space()) and (select public.space_full()));
create policy space_delete on public.clients for delete to authenticated
  using (user_id = (select public.current_space()) and (select public.space_full()));

-- Tiendas y productos: cualquier rol los ve; modificarlos, solo acceso completo
do $p2$
declare t text;
begin
  foreach t in array array['client_locations','products'] loop
    execute format('drop policy if exists space_select on public.%I', t);
    execute format('drop policy if exists space_write on public.%I', t);
    execute format('create policy space_select on public.%I for select to authenticated
      using (user_id = (select public.current_space()))', t);
    execute format('create policy space_write on public.%I for all to authenticated
      using (user_id = (select public.current_space()) and (select public.space_full()))
      with check (user_id = (select public.current_space()) and (select public.space_full()))', t);
  end loop;
end $p2$;

-- Cobros: con rol Depósitos solo los que nacen de un depósito
drop policy if exists space_all on public.pending_collections;
create policy space_all on public.pending_collections for all to authenticated
  using (user_id = (select public.current_space()) and ((select public.space_full()) or deposit_id is not null))
  with check (user_id = (select public.current_space()) and ((select public.space_full()) or deposit_id is not null));

-- ---------------------------------------------------------------------
-- 4) Funciones del servidor: espacio activo en vez de auth.uid()
-- ---------------------------------------------------------------------
do $mig$
declare
  f text; g text; i int;
  r text[][] := array[
    -- Depósitos (cualquier rol del espacio)
    array['public.holded_emit_invoice(uuid,boolean)', 'user_id = auth.uid()', 'user_id = public.current_space()'],
    array['public.holded_send_invoice(uuid,text)',    'user_id = auth.uid()', 'user_id = public.current_space()'],
    array['public.void_signature(uuid,text)',         'user_id = auth.uid()', 'user_id = public.current_space()'],
    array['public.sign_visit(jsonb,text,text,text)',  'and user_id = auth.uid();', 'and user_id = public.current_space();'],
    array['public.sign_visit(jsonb,text,text,text)',  '(auth.uid(), d.id, v_moment', '(d.user_id, d.id, v_moment'],
    array['public.recalc_daily_record(date)',         'v_uid    uuid := auth.uid();', 'v_uid    uuid := public.current_space();'],
    -- Resto de la app (exigen acceso completo)
    array['public.holded_pay_invoice(uuid,date)',     'user_id = auth.uid()', 'user_id = public.space_full_id()'],
    array['public.holded_ping()',                     'where user_id = auth.uid()', 'where user_id = public.space_full_id()'],
    array['public.collect_pending(uuid[],date,uuid)', 'v_uid   uuid := auth.uid();', 'v_uid   uuid := public.space_full_id();'],
    array['public.mark_collections_paid(uuid[],uuid,date)', 'v_uid     uuid := auth.uid();', 'v_uid     uuid := public.space_full_id();'],
    array['public.dashboard_resumen(date)',           'v_uid    uuid := auth.uid();', 'v_uid    uuid := public.space_full_id();'],
    -- Holded: en las facturas de otros espacios, el nombre del espacio en la nota
    array['public.holded_emit_invoice(uuid,boolean)',
          'concat(''Depósito #'', coalesce(d.deposit_number::text, ''?''),',
          'concat(''Depósito #'', coalesce(d.deposit_number::text, ''?''), (select '' · '' || sp.nombre from public.app_spaces sp where sp.owner_id = d.user_id and sp.orden > 1),']
  ];
begin
  for i in 1 .. array_length(r, 1) loop
    f := pg_get_functiondef(r[i][1]::regprocedure);
    if position(r[i][3] in f) > 0 then continue; end if;   -- ya aplicado
    if position(r[i][2] in f) = 0 then
      raise exception 'Migración: no encuentro "%" en %', r[i][2], r[i][1];
    end if;
    g := replace(f, r[i][2], r[i][3]);
    execute g;
  end loop;
end $mig$;

-- recalc_daily_record escribe en daily_records del espacio aunque quien liquide tenga rol Depósitos
alter function public.recalc_daily_record(date) security definer;
revoke all on function public.recalc_daily_record(date) from public, anon;
grant execute on function public.recalc_daily_record(date) to authenticated;

-- ---------------------------------------------------------------------
-- 5) Cambiar la forma de pago (depósito + cobro + Holded)
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
  return public._deposit_set_payment(public.current_space(), p_deposit_id, p_method);
end $$;
revoke all on function public.deposit_set_payment(uuid, text) from public, anon;
grant execute on function public.deposit_set_payment(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6) Nombre del espacio de Tomás (el de JP se crea al dar de alta su usuario)
-- ---------------------------------------------------------------------
insert into public.app_spaces (owner_id, nombre, orden)
select u.id, 'TOMÁS', 1 from auth.users u where u.email = 'santofimiagroup@gmail.com'
on conflict (owner_id) do nothing;

-- =====================================================================
-- ALTA DE JP (cuando exista su usuario en Supabase Auth):
--   insert into public.app_spaces (owner_id, nombre, orden)
--     select id, 'JP', 2 from auth.users where email = 'herazo@magilucards.com';
--   -- JP entra en los Depósitos de Tomás
--   insert into public.app_members (user_id, owner_id, role)
--     select j.id, t.id, 'depositos' from auth.users j, auth.users t
--      where j.email = 'herazo@magilucards.com' and t.email = 'santofimiagroup@gmail.com';
--   -- Tomás entra en todo el espacio de JP
--   insert into public.app_members (user_id, owner_id, role)
--     select t.id, j.id, 'completo' from auth.users j, auth.users t
--      where j.email = 'herazo@magilucards.com' and t.email = 'santofimiagroup@gmail.com';
--   -- Ajustes de JP: factura a nombre de Tomás (mismos datos de empresa)
--   insert into public.settings (user_id, company_legal_name, company_cif)
--     select j.id, s.company_legal_name, s.company_cif from auth.users j, public.settings s, auth.users t
--      where j.email = 'herazo@magilucards.com' and t.email = 'santofimiagroup@gmail.com' and s.user_id = t.id
--   on conflict (user_id) do nothing;
-- QUITAR UN ACCESO: update public.app_members set activo = false where ...;  (efecto inmediato)
-- =====================================================================
