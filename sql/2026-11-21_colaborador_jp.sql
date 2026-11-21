-- =====================================================================
-- MagiluFinance · 2026-11-21 · Colaborador (JP): marca, panel y comisión
-- =====================================================================
--  1) Quién hace cada cosa en un depósito: created_by, recontado_por,
--     facturado_por (los pone el servidor; la app no puede falsearlos).
--  2) Holded: la nota de la factura lleva « · JP» si JP la emite o si el
--     depósito es de su espacio.
--  3) Forma de pago: Holded no deja editar facturas emitidas ("Approved
--     documents cannot be edited"): ya no se intenta; se avisa de cambiarla a mano.
--  4) colab_pagos: % que Tomás paga a JP cada mes y su tipo de IRPF.
--  5) colab_panel(): todo lo de JP para el panel de Tomás.
--     colab_mi_comision(): lo que ve JP en su plan (sin el IRPF de Tomás).
-- Ventas de JP en un mes = depósitos facturados ese mes (fecha de factura)
--   · en el espacio de Tomás que JP recontó o facturó, o
--   · del espacio de JP (también se facturan en el Holded de Tomás).
-- La comisión se calcula sobre la BASE (sin IVA ni RE).
-- =====================================================================

select extensions.urlencode('x');   -- carga http (funciones de Holded con http.timeout_msec)

-- ---------------------------------------------------------------------
-- 1) Quién hizo qué
-- ---------------------------------------------------------------------
alter table public.deposits add column if not exists created_by    uuid;
alter table public.deposits add column if not exists recontado_por uuid;
alter table public.deposits add column if not exists facturado_por uuid;

create or replace function public.track_deposit_people()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(v_uid, new.created_by);
    new.recontado_por := case when new.status in ('recontado', 'facturado') then v_uid end;
    new.facturado_por := case when new.status = 'facturado' then v_uid end;
    return new;
  end if;
  -- En una modificación nadie puede reescribirlos: solo cambian al pasar de estado
  new.created_by := old.created_by;
  new.recontado_por := old.recontado_por;
  new.facturado_por := old.facturado_por;
  if v_uid is not null then
    if new.status = 'recontado' and old.status = 'abierto' then new.recontado_por := v_uid; end if;
    if new.status = 'facturado' and old.status is distinct from 'facturado' then
      new.facturado_por := v_uid;
      if old.status = 'abierto' then new.recontado_por := coalesce(new.recontado_por, v_uid); end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.track_deposit_people() from public, anon, authenticated;
drop trigger if exists tr_deposit_people on public.deposits;
create trigger tr_deposit_people before insert or update on public.deposits
  for each row execute function public.track_deposit_people();

-- La vista de totales los expone (columnas nuevas al final)
create or replace view public.v_deposit_totals with (security_invoker = true) as
 SELECT d.id,
    d.user_id,
    d.client_id,
    d.location_id,
    d.delivery_date,
    d.recount_date,
    d.invoice_date,
    d.status,
    d.regime,
    d.client_has_re,
    d.payment_method,
    d.deposit_number,
    d.holded_invoice_id,
    d.holded_invoice_status,
    d.notes,
    d.client_note,
    d.created_at,
    d.updated_at,
    COALESCE(d.recount_date, d.invoice_date, d.delivery_date) AS dia,
    COALESCE(d.client_has_re, c.vat_regime = 'recargo_equivalencia'::text, false) AS has_re,
    COALESCE(t.n_lines, 0::bigint) AS n_lines,
    COALESCE(t.units_delivered, 0::numeric) AS units_delivered,
    COALESCE(t.units_sold, 0::numeric) AS units_sold,
    COALESCE(t.importe_counted, 0::numeric) AS importe_counted,
    COALESCE(t.valor_deposito, 0::numeric) AS valor_deposito,
    COALESCE(t.base, 0::numeric) AS base,
    COALESCE(t.iva, 0::numeric) AS iva,
    COALESCE(t.re, 0::numeric) AS re,
    COALESCE(t.base, 0::numeric) + COALESCE(t.iva, 0::numeric) + COALESCE(t.re, 0::numeric) AS total,
    pc.status AS collection_status,
    d.created_by,
    d.recontado_por,
    d.facturado_por
   FROM deposits d
     LEFT JOIN clients c ON c.id = d.client_id
     LEFT JOIN LATERAL ( SELECT count(*) AS n_lines,
            sum(dl.qty_delivered) AS units_delivered,
            sum(dl.qty_delivered - dl.qty_remaining) FILTER (WHERE dl.qty_remaining IS NOT NULL) AS units_sold,
            sum((dl.qty_delivered - dl.qty_remaining) * dl.unit_price) FILTER (WHERE dl.qty_remaining IS NOT NULL) AS importe_counted,
            sum(dl.qty_delivered * dl.unit_price) AS valor_deposito,
            sum(x.base) AS base,
            sum(
                CASE
                    WHEN COALESCE(d.regime, 'A'::text) <> 'B'::text THEN x.base * COALESCE(dl.vat_rate, 21)::numeric / 100.0
                    ELSE 0::numeric
                END) AS iva,
            sum(
                CASE
                    WHEN COALESCE(d.regime, 'A'::text) <> 'B'::text AND COALESCE(d.client_has_re, c.vat_regime = 'recargo_equivalencia'::text, false) THEN x.base *
                    CASE COALESCE(dl.vat_rate, 21)
                        WHEN 21 THEN 0.052
                        WHEN 10 THEN 0.014
                        WHEN 4 THEN 0.005
                        ELSE 0::numeric
                    END
                    ELSE 0::numeric
                END) AS re
           FROM deposit_lines dl
             CROSS JOIN LATERAL ( SELECT (dl.qty_delivered - COALESCE(dl.qty_remaining, 0::numeric)) * dl.unit_price AS base) x
          WHERE dl.deposit_id = d.id) t ON true
     LEFT JOIN LATERAL ( SELECT p.status
           FROM pending_collections p
          WHERE p.deposit_id = d.id
         LIMIT 1) pc ON true;

-- ---------------------------------------------------------------------
-- 2) Holded: marca « · JP» en la nota (quien factura o espacio del depósito)
-- ---------------------------------------------------------------------
do $mig$
declare f text; v_old text; v_new text;
begin
  f := pg_get_functiondef('public.holded_emit_invoice(uuid,boolean)'::regprocedure);
  v_old := '(select '' · '' || sp.nombre from public.app_spaces sp where sp.owner_id = d.user_id and sp.orden > 1),';
  v_new := '(select '' · '' || string_agg(distinct sp.nombre, '' · '') from public.app_spaces sp where sp.orden > 1 and sp.owner_id in (d.user_id, auth.uid())),';
  if position(v_new in f) > 0 then return; end if;
  if position(v_old in f) = 0 then raise exception 'Migración: no encuentro la marca de espacio en holded_emit_invoice'; end if;
  execute replace(f, v_old, v_new);
end $mig$;

-- ---------------------------------------------------------------------
-- 3) Forma de pago: sin intentar editar la factura emitida en Holded
-- ---------------------------------------------------------------------
create or replace function public._deposit_set_payment(p_owner uuid, p_deposit_id uuid, p_method text)
returns jsonb language plpgsql security definer set search_path = 'public'
as $$
declare d record; v_cobro text := null;
begin
  if p_owner is null then raise exception 'No autenticado'; end if;
  if p_method is null or p_method not in ('efectivo','tarjeta','transferencia','bizum','pagare','remesa','otro') then
    raise exception 'Forma de pago no válida';
  end if;
  select * into d from deposits where id = p_deposit_id and user_id = p_owner for update;
  if d.id is null then raise exception 'Depósito no encontrado'; end if;
  if d.status not in ('recontado', 'facturado') then raise exception 'La forma de pago se elige al liquidar el depósito'; end if;
  update deposits set payment_method = p_method, updated_at = now() where id = d.id;
  update pending_collections set payment_method = p_method
   where deposit_id = d.id and user_id = p_owner returning status into v_cobro;
  return jsonb_build_object('ok', true, 'payment_method', p_method, 'cobro_status', v_cobro,
    'holded', case when d.holded_invoice_id is null then 'sin_factura' else 'manual' end,
    'holded_msg', case when d.holded_invoice_id is not null then
      'Holded no deja modificar una factura ya emitida. Si quieres que la factura lo diga, cambia la forma de pago a mano en Holded.' end);
end $$;
revoke all on function public._deposit_set_payment(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) % que se paga al colaborador cada mes
-- ---------------------------------------------------------------------
create table if not exists public.colab_pagos (
  owner_id   uuid not null references auth.users(id) on delete cascade,
  colab_id   uuid not null references auth.users(id) on delete cascade,
  mes        date not null check (mes = date_trunc('month', mes)::date),
  pct        numeric(5,2) not null check (pct between 0 and 100),
  irpf_pct   numeric(5,2) not null check (irpf_pct between 0 and 60),
  updated_at timestamptz not null default now(),
  primary key (owner_id, colab_id, mes)
);
alter table public.colab_pagos enable row level security;
drop policy if exists colab_pagos_owner on public.colab_pagos;
create policy colab_pagos_owner on public.colab_pagos for select to authenticated
  using (owner_id = (select auth.uid()));
-- Se guarda solo con colab_guardar_pct() (comprueba que es colaborador tuyo)

create or replace function public.colab_guardar_pct(p_colab uuid, p_mes date, p_pct numeric, p_irpf numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;
  if not exists (select 1 from public.app_members m where m.user_id = p_colab and m.owner_id = auth.uid()) then
    raise exception 'No es colaborador tuyo' using errcode = '42501';
  end if;
  insert into public.colab_pagos (owner_id, colab_id, mes, pct, irpf_pct)
  values (auth.uid(), p_colab, date_trunc('month', p_mes)::date, p_pct, p_irpf)
  on conflict (owner_id, colab_id, mes) do update set pct = excluded.pct, irpf_pct = excluded.irpf_pct, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.colab_guardar_pct(uuid, date, numeric, numeric) from public, anon;
grant execute on function public.colab_guardar_pct(uuid, date, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 5) Datos del panel (Tomás) y de la comisión (JP)
-- ---------------------------------------------------------------------
-- Depósitos de un colaborador vistos por el dueño (fila por depósito)
create or replace function public._colab_ventas(p_owner uuid, p_colab uuid, p_incluir_su_espacio boolean)
returns table (id uuid, espacio text, deposit_number integer, cliente text, status text,
               delivery_date date, recount_date date, invoice_date date, base numeric, total numeric,
               coste numeric, payment_method text, collection_status text, en_holded boolean,
               creado boolean, recontado boolean, facturado boolean, cuenta boolean)
language sql stable security definer set search_path = ''
as $$
  select v.id, coalesce(sp.nombre, '') as espacio, v.deposit_number,
         coalesce(nullif(c.commercial_name, ''), c.legal_name) as cliente, v.status,
         v.delivery_date, v.recount_date, v.invoice_date, round(v.base, 2), round(v.total, 2),
         round(coalesce((select sum((dl.qty_delivered - coalesce(dl.qty_remaining, 0)) * coalesce(dl.unit_cost, 0))
                           from public.deposit_lines dl where dl.deposit_id = v.id), 0), 2) as coste,
         v.payment_method, v.collection_status, v.holded_invoice_id is not null,
         coalesce(v.created_by = p_colab, false), coalesce(v.recontado_por = p_colab, false),
         coalesce(v.facturado_por = p_colab, false),
         -- ¿Cuenta para la comisión? recontado o facturado por él, o de su espacio
         coalesce(v.user_id = p_colab or v.recontado_por = p_colab or v.facturado_por = p_colab, false)
    from public.v_deposit_totals v
    left join public.clients c on c.id = v.client_id
    left join public.app_spaces sp on sp.owner_id = v.user_id
   where (v.user_id = p_owner and p_colab in (v.created_by, v.recontado_por, v.facturado_por))
      or (p_incluir_su_espacio and v.user_id = p_colab)
$$;
revoke all on function public._colab_ventas(uuid, uuid, boolean) from public, anon, authenticated;

-- Panel de Tomás: sus colaboradores, depósitos de uno de ellos, % guardados y su reserva IRPF del plan
create or replace function public.colab_panel(p_colab uuid default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := auth.uid(); v_colab uuid := p_colab; v_su boolean;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  if v_colab is null then
    select m.user_id into v_colab from public.app_members m left join public.app_spaces s on s.owner_id = m.user_id
     where m.owner_id = v_uid order by coalesce(s.orden, 99) limit 1;
  end if;
  if v_colab is not null and not exists (select 1 from public.app_members m where m.user_id = v_colab and m.owner_id = v_uid) then
    raise exception 'No es colaborador tuyo' using errcode = '42501';
  end if;
  -- Sus depósitos propios solo si tienes acceso completo a su espacio
  v_su := exists (select 1 from public.app_members m where m.user_id = v_uid and m.owner_id = v_colab and m.activo and m.role = 'completo');
  return jsonb_build_object(
    'colabs', coalesce((select jsonb_agg(jsonb_build_object('id', m.user_id, 'nombre', coalesce(s.nombre, u.email), 'activo', m.activo)
                                         order by coalesce(s.orden, 99))
                          from public.app_members m join auth.users u on u.id = m.user_id
                          left join public.app_spaces s on s.owner_id = m.user_id
                         where m.owner_id = v_uid), '[]'::jsonb),
    'colab', v_colab,
    'su_espacio', v_su,
    'ventas', coalesce((select jsonb_agg(to_jsonb(x) order by coalesce(x.invoice_date, x.recount_date, x.delivery_date) desc, x.deposit_number desc)
                          from public._colab_ventas(v_uid, v_colab, v_su) x), '[]'::jsonb),
    'pagos', coalesce((select jsonb_agg(jsonb_build_object('mes', p.mes, 'pct', p.pct, 'irpf_pct', p.irpf_pct) order by p.mes)
                         from public.colab_pagos p where p.owner_id = v_uid and p.colab_id = v_colab), '[]'::jsonb),
    'irpf_plan', (select nullif(e.field_value, '') from public.editable_data e
                   where e.user_id = v_uid and e.item_key = 'plan' and e.field_key = 'irpf_pct' limit 1)
  );
end $$;
revoke all on function public.colab_panel(uuid) from public, anon;
grant execute on function public.colab_panel(uuid) to authenticated;

-- Lo que ve el colaborador en su plan: base de sus ventas del mes, % fijado y pago (sin el IRPF del dueño)
create or replace function public.colab_mi_comision(p_mes date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'dueno', coalesce(s.nombre, 'Dueño'),
           'ventas', coalesce(v.n, 0), 'base', coalesce(v.base, 0),
           'pct', p.pct,
           'pago', case when p.pct is null then null else round(coalesce(v.base, 0) * p.pct / 100, 2) end)), '[]'::jsonb)
    from public.app_members m
    left join public.app_spaces s on s.owner_id = m.owner_id
    left join public.colab_pagos p on p.owner_id = m.owner_id and p.colab_id = m.user_id
                                  and p.mes = date_trunc('month', p_mes)::date
    left join lateral (
      select count(*) n, round(sum(x.base), 2) base
        from public._colab_ventas(m.owner_id, m.user_id, true) x
       where x.cuenta and x.status = 'facturado'
         and x.invoice_date >= date_trunc('month', p_mes)::date
         and x.invoice_date <  (date_trunc('month', p_mes) + interval '1 month')::date
    ) v on true
   where m.user_id = auth.uid() and m.activo and m.role = 'depositos'
$$;
revoke all on function public.colab_mi_comision(date) from public, anon;
grant execute on function public.colab_mi_comision(date) to authenticated;

-- ---------------------------------------------------------------------
-- 6) (aplicado aparte) Colaborador = rol 'depositos'. Tomás tiene acceso
--    'completo' al espacio de JP, y eso NO convierte a Tomás en colaborador de JP.
-- ---------------------------------------------------------------------
do $mig$
declare f text; i int;
  fns text[] := array['public.colab_panel(uuid)', 'public.colab_guardar_pct(uuid,date,numeric,numeric)'];
begin
  for i in 1 .. array_length(fns, 1) loop
    f := pg_get_functiondef(fns[i]::regprocedure);
    if position('m.role = ''depositos''' in f) > 0 then continue; end if;
    f := replace(f, 'where m.user_id = v_colab and m.owner_id = v_uid)', 'where m.user_id = v_colab and m.owner_id = v_uid and m.role = ''depositos'')');
    f := replace(f, 'where m.user_id = p_colab and m.owner_id = auth.uid())', 'where m.user_id = p_colab and m.owner_id = auth.uid() and m.role = ''depositos'')');
    f := replace(f, 'where m.owner_id = v_uid order by', 'where m.owner_id = v_uid and m.role = ''depositos'' order by');
    f := replace(f, 'where m.owner_id = v_uid), ''[]''::jsonb)', 'where m.owner_id = v_uid and m.role = ''depositos''), ''[]''::jsonb)');
    if position('m.role = ''depositos''' in f) = 0 then raise exception 'No se aplicó en %', fns[i]; end if;
    execute f;
  end loop;
end $mig$;

-- ---------------------------------------------------------------------
-- 7) (aplicado aparte) Productos de Tomás copiados al espacio de JP SIN costes
--    (41 productos: mismo código, nombre, precio, IVA y estado; coste 0).
--    Para el margen del panel de Tomás, si una línea no tiene coste, _colab_ventas
--    usa el coste del producto de Tomás con la misma referencia (JP no lo ve).
--    Ver la versión de _colab_ventas con «coalesce(nullif(dl.unit_cost, 0), …)».
-- ---------------------------------------------------------------------
