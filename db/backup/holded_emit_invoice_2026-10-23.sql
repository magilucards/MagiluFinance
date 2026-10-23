CREATE OR REPLACE FUNCTION public.holded_emit_invoice(p_deposit_id uuid, p_draft boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_key text; d record; c record;
  v_contact_id text; v_contacts jsonb; v_items jsonb; v_taxes jsonb; v_body jsonb;
  v_date bigint; v_resp record; v_content jsonb; v_invoice_id text; v_pm text;
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;

  select * into d from deposits where id = p_deposit_id and user_id = auth.uid() for update;
  if d.id is null then raise exception 'Depósito no encontrado'; end if;
  if coalesce(d.regime,'A') <> 'A' then raise exception 'Solo se facturan en Holded los depósitos en régimen A'; end if;
  if d.holded_invoice_id is not null then raise exception 'Este depósito ya tiene factura en Holded (%).', d.holded_invoice_id; end if;

  select * into c from clients where id = d.client_id and user_id = auth.uid();
  if c.id is null then raise exception 'Cliente del depósito no encontrado'; end if;
  if coalesce(trim(c.nif),'') = '' then raise exception 'El cliente no tiene NIF; no se puede cruzar con Holded'; end if;

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
    'items', v_items, 'notes', concat('Depósito #', coalesce(d.deposit_number::text, '?')));
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
end; $function$
