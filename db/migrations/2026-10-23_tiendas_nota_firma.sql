-- YA APLICADA en Supabase el 23-oct-2026 (desde el chat). Solo referencia: NO volver a ejecutar.
-- =====================================================================
-- MagiluFinance · Migración "tiendas_nota_firma" · 23-oct-2026
-- =====================================================================

-- 1) TIENDAS POR CLIENTE ----------------------------------------------
create table public.client_locations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id),
  client_id   uuid not null references public.clients(id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  address     text,
  city        text,
  postal_code text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint client_locations_id_client_uq unique (id, client_id)
);

create unique index client_locations_client_name_uq
  on public.client_locations (client_id, lower(trim(name)));

alter table public.client_locations enable row level security;

create policy own_client_locations on public.client_locations
  for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create trigger tr_client_locations_updated
  before update on public.client_locations
  for each row execute function public.update_updated_at();

-- 2) DEPÓSITOS: TIENDA + NOTA VISIBLE PARA EL CLIENTE ------------------
alter table public.deposits
  add column location_id uuid,
  add column client_note text;

-- FK compuesta: la tienda tiene que ser del mismo cliente que el depósito
alter table public.deposits
  add constraint deposits_location_fk
  foreign key (location_id, client_id)
  references public.client_locations (id, client_id)
  on delete restrict;

create index deposits_location_id_idx on public.deposits (location_id);

comment on column public.deposits.notes is
  'Nota INTERNA. Nunca se imprime en el PDF del cliente.';
comment on column public.deposits.client_note is
  'Nota VISIBLE para el cliente: se imprime en el PDF del depósito.';

-- 3) CLIENTES: EXIGE FIRMA --------------------------------------------
alter table public.clients
  add column requires_signature boolean not null default false;

-- 4) BACKFILL: tiendas a partir de las notas "Tienda X" ----------------
insert into public.client_locations (user_id, client_id, name)
select distinct on (d.client_id, lower(trim(substr(d.notes, 8))))
       d.user_id, d.client_id, trim(substr(d.notes, 8))
  from public.deposits d
 where d.notes ilike 'Tienda %'
 order by d.client_id, lower(trim(substr(d.notes, 8))), d.delivery_date desc
on conflict do nothing;

update public.deposits d
   set location_id = l.id
  from public.client_locations l
 where d.notes ilike 'Tienda %'
   and d.location_id is null
   and l.client_id = d.client_id
   and lower(trim(l.name)) = lower(trim(substr(d.notes, 8)));

-- 5) FIRMAS ----------------------------------------------------------
create table public.deposit_signatures (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id),
  deposit_id       uuid not null references public.deposits(id) on delete restrict,
  moment           text not null check (moment in ('entrega', 'recuento')),
  signer_name      text not null check (length(trim(signer_name)) > 0),
  signature_png    text not null check (signature_png like 'data:image/png;base64,%'),
  content_snapshot jsonb not null,
  content_hash     text not null,
  signed_at        timestamptz not null default now(),
  device_info      text,
  voided_at        timestamptz,
  void_reason      text
);

-- Una sola firma activa por depósito y momento
create unique index deposit_signatures_active_uq
  on public.deposit_signatures (deposit_id, moment)
  where voided_at is null;

create index deposit_signatures_deposit_idx
  on public.deposit_signatures (deposit_id);

alter table public.deposit_signatures enable row level security;

-- La app solo lee. Para escribir: sign_visit / void_signature (SECURITY DEFINER).
create policy deposit_signatures_select_own on public.deposit_signatures
  for select using ((select auth.uid()) = user_id);

-- Una firma no se edita: solo se anula, y una sola vez.
create or replace function public.guard_signature_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.voided_at is not null then
    raise exception 'Esta firma ya está anulada';
  end if;
  if new.voided_at is null
     or (new.id, new.user_id, new.deposit_id, new.moment, new.signer_name,
         new.signature_png, new.content_snapshot, new.content_hash,
         new.signed_at, new.device_info)
        is distinct from
        (old.id, old.user_id, old.deposit_id, old.moment, old.signer_name,
         old.signature_png, old.content_snapshot, old.content_hash,
         old.signed_at, old.device_info) then
    raise exception 'Una firma no se modifica: solo se puede anular';
  end if;
  return new;
end;
$$;

create trigger tr_guard_signature_update
  before update on public.deposit_signatures
  for each row execute function public.guard_signature_update();

-- 6) CONTENIDO CONGELADO DE LO QUE SE FIRMA ---------------------------
create or replace function public._deposit_snapshot(p_deposit_id uuid, p_moment text)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'deposito',       d.deposit_number,
    'momento',        p_moment,
    'fecha_entrega',  d.delivery_date,
    'fecha_recuento', d.recount_date,
    'cliente', jsonb_build_object(
        'razon_social',     c.legal_name,
        'nif',              c.nif,
        'nombre_comercial', c.commercial_name),
    'tienda', case when l.id is null then null else jsonb_build_object(
        'nombre',    l.name,
        'direccion', l.address,
        'poblacion', l.city,
        'cp',        l.postal_code) end,
    'nota_cliente', nullif(trim(d.client_note), ''),
    'lineas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'codigo',     dl.product_code,
                 'producto',   dl.product_name,
                 'entregadas', dl.qty_delivered,
                 'quedan',     dl.qty_remaining,
                 'vendidas',   dl.qty_delivered - dl.qty_remaining,
                 'precio',     dl.unit_price,
                 'iva',        dl.vat_rate)
               order by dl.sort_order, dl.product_code)
          from deposit_lines dl
         where dl.deposit_id = d.id), '[]'::jsonb))
  from deposits d
  join clients c on c.id = d.client_id
  left join client_locations l on l.id = d.location_id
  where d.id = p_deposit_id;
$$;

revoke all on function public._deposit_snapshot(uuid, text) from public, anon, authenticated;

-- 7) FIRMAR UNA VISITA (una firma → una o varias filas, todo o nada) -------
create or replace function public.sign_visit(
  p_items         jsonb,   -- [{"deposit_id":"<uuid>","moment":"recuento"}, {"deposit_id":"<uuid>","moment":"entrega"}]
  p_signer_name   text,
  p_signature_png text,
  p_device_info   text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item   jsonb;
  v_moment text;
  d        record;
  v_snap   jsonb;
  v_hash   text;
  v_id     uuid;
  v_out    jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;
  if coalesce(trim(p_signer_name), '') = '' then
    raise exception 'Falta el nombre de quien firma';
  end if;
  if coalesce(p_signature_png, '') not like 'data:image/png;base64,%' then
    raise exception 'La firma no es válida';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'No hay nada que firmar';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'No hay nada que firmar';
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_moment := v_item->>'moment';
    if v_moment is null or v_moment not in ('entrega', 'recuento') then
      raise exception 'Momento de firma no válido';
    end if;

    select * into d
      from deposits
     where id = (v_item->>'deposit_id')::uuid
       and user_id = auth.uid();
    if d.id is null then raise exception 'Depósito no encontrado'; end if;

    if v_moment = 'recuento' and d.recount_date is null then
      raise exception 'El depósito #% aún no está recontado', d.deposit_number;
    end if;
    if exists (select 1 from deposit_signatures s
                where s.deposit_id = d.id
                  and s.moment = v_moment
                  and s.voided_at is null) then
      raise exception 'El depósito #% ya tiene firma de %', d.deposit_number, v_moment;
    end if;

    v_snap := public._deposit_snapshot(d.id, v_moment);
    v_hash := encode(extensions.digest(convert_to(v_snap::text, 'UTF8'), 'sha256'), 'hex');

    insert into deposit_signatures
      (user_id, deposit_id, moment, signer_name, signature_png,
       content_snapshot, content_hash, device_info)
    values
      (auth.uid(), d.id, v_moment, trim(p_signer_name), p_signature_png,
       v_snap, v_hash, p_device_info)
    returning id into v_id;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'signature_id', v_id, 'deposit_id', d.id, 'moment', v_moment, 'hash', v_hash));
  end loop;

  return jsonb_build_object('ok', true, 'signed_at', now(), 'firmas', v_out);
end;
$$;

revoke all on function public.sign_visit(jsonb, text, text, text) from public, anon;
grant execute on function public.sign_visit(jsonb, text, text, text) to authenticated;

-- 8) ANULAR UNA FIRMA -------------------------------------------------
create or replace function public.void_signature(p_signature_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Indica el motivo de la anulación';
  end if;
  update deposit_signatures
     set voided_at = now(), void_reason = trim(p_reason)
   where id = p_signature_id
     and user_id = auth.uid()
     and voided_at is null;
  if not found then raise exception 'Firma no encontrada o ya anulada'; end if;
end;
$$;

revoke all on function public.void_signature(uuid, text) from public, anon;
grant execute on function public.void_signature(uuid, text) to authenticated;

-- 9) FIRMADO = BLOQUEADO ---------------------------------------------
create or replace function public.guard_signed_deposit_lines()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_dep      uuid;
  v_entrega  boolean;
  v_recuento boolean;
  v_econ     boolean := true;  -- cambia lo entregado: producto, cantidad, precio, IVA
  v_count    boolean := true;  -- cambia lo recontado
begin
  if tg_op = 'DELETE' then v_dep := old.deposit_id; else v_dep := new.deposit_id; end if;

  select coalesce(bool_or(moment = 'entrega'), false),
         coalesce(bool_or(moment = 'recuento'), false)
    into v_entrega, v_recuento
    from deposit_signatures
   where deposit_id = v_dep and voided_at is null;

  if tg_op = 'UPDATE' then
    v_econ := (new.deposit_id, new.product_id, new.product_code, new.product_name,
               new.qty_delivered, new.unit_price, new.vat_rate)
              is distinct from
              (old.deposit_id, old.product_id, old.product_code, old.product_name,
               old.qty_delivered, old.unit_price, old.vat_rate);
    v_count := new.qty_remaining is distinct from old.qty_remaining;
  end if;

  if v_recuento and (v_econ or v_count) then
    raise exception 'Depósito con el recuento firmado: anula la firma para modificarlo';
  end if;
  if v_entrega and v_econ then
    raise exception 'Depósito con la entrega firmada: solo se puede registrar el recuento (o anula la firma)';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger tr_guard_signed_deposit_lines
  before insert or update or delete on public.deposit_lines
  for each row execute function public.guard_signed_deposit_lines();

create or replace function public.guard_signed_deposit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_entrega  boolean;
  v_recuento boolean;
begin
  select coalesce(bool_or(moment = 'entrega'), false),
         coalesce(bool_or(moment = 'recuento'), false)
    into v_entrega, v_recuento
    from deposit_signatures
   where deposit_id = old.id and voided_at is null;

  if (v_entrega or v_recuento)
     and (new.client_id, new.location_id, new.delivery_date, new.client_note)
         is distinct from
         (old.client_id, old.location_id, old.delivery_date, old.client_note) then
    raise exception 'Depósito firmado: anula la firma para cambiar cliente, tienda, fecha o nota';
  end if;
  if v_recuento and new.recount_date is distinct from old.recount_date then
    raise exception 'Recuento firmado: anula la firma para cambiar la fecha de recuento';
  end if;
  return new;
end;
$$;

create trigger tr_guard_signed_deposit
  before update on public.deposits
  for each row execute function public.guard_signed_deposit();

-- 10) FACTURACIÓN: tienda en la nota de Holded + exigencia de firma -------
-- Copia literal de la función actual con dos añadidos marcados como NUEVO.
create or replace function public.holded_emit_invoice(p_deposit_id uuid, p_draft boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_key text; d record; c record;
  v_contact_id text; v_contacts jsonb; v_items jsonb; v_taxes jsonb; v_body jsonb;
  v_date bigint; v_resp record; v_content jsonb; v_invoice_id text; v_pm text;
  v_loc_name text;  -- NUEVO
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;

  select * into d from deposits where id = p_deposit_id and user_id = auth.uid() for update;
  if d.id is null then raise exception 'Depósito no encontrado'; end if;
  if coalesce(d.regime,'A') <> 'A' then raise exception 'Solo se facturan en Holded los depósitos en régimen A'; end if;
  if d.holded_invoice_id is not null then raise exception 'Este depósito ya tiene factura en Holded (%).', d.holded_invoice_id; end if;

  select * into c from clients where id = d.client_id and user_id = auth.uid();
  if c.id is null then raise exception 'Cliente del depósito no encontrado'; end if;
  if coalesce(trim(c.nif),'') = '' then raise exception 'El cliente no tiene NIF; no se puede cruzar con Holded'; end if;

  -- NUEVO · cliente que exige firma: no se emite (salvo borrador) sin el recuento firmado
  if not p_draft and coalesce(c.requires_signature, false) and not exists (
       select 1 from deposit_signatures s
        where s.deposit_id = d.id and s.moment = 'recuento' and s.voided_at is null) then
    raise exception 'Este cliente exige el recuento firmado antes de facturar.';
  end if;

  -- NUEVO · tienda del depósito (clientes con varias tiendas)
  if d.location_id is not null then
    select name into v_loc_name from client_locations where id = d.location_id;
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name='HOLDED_API_KEY' limit 1;
  if v_key is null then raise exception 'HOLDED_API_KEY no está en Vault'; end if;

  select r.status, r.content into v_resp from extensions.http((
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

  if coalesce(d.client_has_re, (c.vat_regime = 'recargo_equivalencia'), false)
    then v_taxes := '["s_iva_21","s_rec_52"]'::jsonb;
    else v_taxes := '["s_iva_21"]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', dl.product_name,
           'units', (dl.qty_delivered - coalesce(dl.qty_remaining,0)),
           'subtotal', dl.unit_price,
           'taxes', v_taxes)), '[]'::jsonb)
  into v_items
  from deposit_lines dl
  where dl.deposit_id = d.id and (dl.qty_delivered - coalesce(dl.qty_remaining,0)) > 0;
  if v_items = '[]'::jsonb then raise exception 'El depósito no tiene unidades vendidas que facturar'; end if;

  v_date := extract(epoch from (coalesce(d.recount_date, d.invoice_date, d.delivery_date)::timestamp + interval '12 hours'))::bigint;

  -- Forma de pago de la app → id de Holded (paymentmethods). Bizum/efectivo → Pago al contado.
  v_pm := case d.payment_method
    when 'efectivo'      then '6a10cbd45deee2e3640a7950'  -- Pago al contado
    when 'bizum'         then '6a10cbd45deee2e3640a7950'  -- (no hay Bizum en Holded) → contado
    when 'transferencia' then '6a10cbd45deee2e3640a794f'  -- Transferencia bancaria
    when 'remesa'        then '6a10e06b4a12b5dcb80436d4'  -- Remesa
    when 'pagare'        then '6a10e0b7ebc18cbd9305531f'  -- Pagaré
    when 'tarjeta'       then '6a10e2b5ef889e37d10652e7'  -- Tarjeta
    else null end;

  v_body := jsonb_build_object(
    'contactId', v_contact_id, 'date', v_date, 'approveDoc', (not p_draft),
    'items', v_items,
    'notes', concat('Depósito #', coalesce(d.deposit_number::text, '?'),
                    case when v_loc_name is not null then ' · Tienda ' || v_loc_name end));  -- NUEVO: tienda
  if v_pm is not null then v_body := v_body || jsonb_build_object('paymentMethodId', v_pm); end if;

  select r.status, r.content into v_resp from extensions.http((
    'POST','https://api.holded.com/api/invoicing/v1/documents/invoice',
    array[extensions.http_header('key', v_key)],
    'application/json', v_body::text)::extensions.http_request) r;

  if v_resp.status <> 200 then raise exception 'Holded devolvió status % al crear la factura: %', v_resp.status, left(coalesce(v_resp.content,''), 300); end if;
  begin v_content := v_resp.content::jsonb;
  exception when others then raise exception 'Holded devolvió una respuesta no válida al crear la factura'; end;
  if coalesce(v_content->>'status','0') <> '1' then raise exception 'Holded rechazó la factura: %', v_resp.content; end if;
  v_invoice_id := v_content->>'id';

  if not p_draft then
    update deposits set
      holded_invoice_id = v_invoice_id,
      holded_invoice_status = 'emitida',
      status = case when status = 'recontado' then 'facturado' else status end,
      invoice_date = coalesce(invoice_date, recount_date, current_date),
      updated_at = now()
    where id = d.id;
  end if;

  return jsonb_build_object('ok', true, 'draft', p_draft,
    'invoice_id', v_invoice_id, 'invoiceNum', v_content->>'invoiceNum', 'contactId', v_contact_id);
end; $function$;
