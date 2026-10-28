-- =====================================================================
-- MagiluFinance · 2026-10-28 · Dashboard + gastos del día
-- =====================================================================
-- Qué crea (no modifica tablas, datos ni funciones existentes):
--   1) Tabla  public.expenses  — gastos que Tomás apunta a mano (gasoil,
--      peajes, comida… concepto libre) con su fecha. RLS: cada usuario
--      solo ve y toca los suyos (mismo patrón que movements/daily_records).
--      No mueve saldos de cuentas: es solo para la estadística de ganancia.
--   2) RPC    public.dashboard_resumen(p_mes date)  → jsonb con todo lo que
--      pinta dashboard.html (la app recibe resultados, no filas).
--
-- Criterios (los mismos que ya usa la app):
--   · Ventas del mes: depósitos recontados o facturados cuyo día de
--     liquidación (recount_date → invoice_date → delivery_date) cae en el mes.
--   · Neto = base sin impuestos (A + B). Bruto = con IVA + RE (B no lleva).
--     Sale de v_deposit_totals (2026-10-28_totales_deposito.sql).
--   · Coste de lo vendido = vendido × unit_cost congelado en la línea.
--   · Ganancia = neto − coste de lo vendido − gastos del mes.
--   · Tarjetas = referencias que empiezan por MGE, MGI o NAVI (y nada más:
--     MAXI, MINI, CU, MPT, ETIQ… cuentan como "otros productos"). Ver v_prefijos.
--   · Stock en la calle = lo entregado en depósitos ABIERTOS (sin recontar).
--   · Clientes activos = clients.is_client y is_active. Visitado en el año
--     = tiene algún depósito entregado o recontado ese año.
--
-- La app nueva (dashboard.html) NECESITA esto aplicado antes de publicarse.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Gastos
-- ---------------------------------------------------------------------
create table if not exists public.expenses (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  expense_date date not null default current_date,
  concept      text not null check (char_length(btrim(concept)) between 1 and 80),
  amount       numeric(12,2) not null check (amount > 0 and amount < 100000),
  notes        text check (notes is null or char_length(notes) <= 300),
  created_at   timestamptz not null default now()
);

comment on table public.expenses is
  'Gastos apuntados a mano (gasoil, peajes, comida…) para calcular la ganancia real en el dashboard. No mueve saldos.';

create index if not exists idx_expenses_user_date on public.expenses (user_id, expense_date desc);

alter table public.expenses enable row level security;

drop policy if exists own_expenses on public.expenses;
create policy own_expenses on public.expenses
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on public.expenses from public, anon;
grant select, insert, update, delete on public.expenses to authenticated;


-- ---------------------------------------------------------------------
-- 2) Resumen del dashboard
-- ---------------------------------------------------------------------
create or replace function public.dashboard_resumen(p_mes date)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid    uuid := auth.uid();
  v_desde  date;
  v_hasta  date;
  v_anio_desde date;
  v_anio_hasta date;
  -- Qué cuenta como "tarjeta" (referencias que empiezan por…)
  v_prefijos text[] := array['MGE', 'MGI', 'NAVI'];
  r jsonb := '{}'::jsonb;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  if p_mes is null then raise exception 'Falta el mes'; end if;

  v_desde := date_trunc('month', p_mes)::date;
  v_hasta := (date_trunc('month', p_mes) + interval '1 month - 1 day')::date;
  v_anio_desde := date_trunc('year', p_mes)::date;
  v_anio_hasta := (date_trunc('year', p_mes) + interval '1 year - 1 day')::date;

  r := r || jsonb_build_object('desde', v_desde, 'hasta', v_hasta);

  -- Ventas del mes (neto / bruto, A / B)
  r := r || (
    select jsonb_build_object('ventas', jsonb_build_object(
      'liquidaciones', count(*),
      'neto',     round(coalesce(sum(v.base), 0), 2),
      'bruto',    round(coalesce(sum(v.total), 0), 2),
      'iva',      round(coalesce(sum(v.iva), 0), 2),
      're',       round(coalesce(sum(v.re), 0), 2),
      'neto_a',   round(coalesce(sum(v.base)  filter (where coalesce(v.regime,'A') <> 'B'), 0), 2),
      'neto_b',   round(coalesce(sum(v.base)  filter (where v.regime = 'B'), 0), 2),
      'bruto_a',  round(coalesce(sum(v.total) filter (where coalesce(v.regime,'A') <> 'B'), 0), 2)
    ))
    from v_deposit_totals v
    where v.user_id = v_uid
      and v.status in ('recontado', 'facturado')
      and v.dia between v_desde and v_hasta
  );

  -- Lo vendido en el mes, línea a línea: coste, tarjetas y otros productos
  with vendido as (
    select dl.product_code,
           coalesce(p.name, dl.product_name) as nombre,
           (dl.qty_delivered - coalesce(dl.qty_remaining, 0))                 as uds,
           (dl.qty_delivered - coalesce(dl.qty_remaining, 0)) * dl.unit_cost  as coste,
           (dl.qty_delivered - coalesce(dl.qty_remaining, 0)) * dl.unit_price as base,
           exists (select 1 from unnest(v_prefijos) pr where upper(dl.product_code) like pr || '%') as es_tarjeta
    from deposits d
    join deposit_lines dl on dl.deposit_id = d.id
    left join products p on p.id = dl.product_id
    where d.user_id = v_uid
      and d.status in ('recontado', 'facturado')
      and coalesce(d.recount_date, d.invoice_date, d.delivery_date) between v_desde and v_hasta
  )
  select r || jsonb_build_object(
    'coste_vendido',        round(coalesce(sum(coste), 0), 2),
    'tarjetas_vendidas',    coalesce(sum(uds) filter (where es_tarjeta), 0),
    'tarjetas_por_ref', coalesce((
        select jsonb_agg(jsonb_build_object('ref', product_code, 'uds', u) order by u desc)
        from (select product_code, sum(uds) u from vendido where es_tarjeta group by 1 having sum(uds) > 0) t), '[]'::jsonb),
    'otros_vendidos', coalesce((
        select jsonb_agg(jsonb_build_object('ref', product_code, 'nombre', nombre, 'uds', u) order by u desc)
        from (select product_code, max(nombre) nombre, sum(uds) u from vendido where not es_tarjeta group by 1 having sum(uds) > 0) t), '[]'::jsonb)
  )
  into r
  from vendido;

  -- Gastos del mes (total, por concepto y por día)
  r := r || (
    select jsonb_build_object(
      'gastos', round(coalesce(sum(e.amount), 0), 2),
      'gastos_por_concepto', coalesce((
          select jsonb_agg(jsonb_build_object('concepto', c, 'importe', i) order by i desc)
          from (select initcap(lower(btrim(concept))) c, round(sum(amount), 2) i
                from expenses
                where user_id = v_uid and expense_date between v_desde and v_hasta
                group by 1) t), '[]'::jsonb)
    )
    from expenses e
    where e.user_id = v_uid and e.expense_date between v_desde and v_hasta
  );

  -- Ganancia real del mes
  r := r || jsonb_build_object('ganancia', round(
            (r #>> '{ventas,neto}')::numeric - (r ->> 'coste_vendido')::numeric - (r ->> 'gastos')::numeric, 2));

  -- Top 10 tiendas del mes (bruto)
  r := r || jsonb_build_object('top_tiendas', coalesce((
    select jsonb_agg(jsonb_build_object('cliente', cliente, 'bruto', bruto) order by bruto desc)
    from (
      select coalesce(c.commercial_name, c.legal_name, '—')
               || coalesce(' · ' || l.name, '') as cliente,
             round(sum(v.total), 2) as bruto
      from v_deposit_totals v
      left join clients c on c.id = v.client_id
      left join client_locations l on l.id = v.location_id
      where v.user_id = v_uid
        and v.status in ('recontado', 'facturado')
        and v.dia between v_desde and v_hasta
      group by 1
      order by 2 desc
      limit 10
    ) t), '[]'::jsonb));

  -- Stock en la calle (hoy): depósitos abiertos
  with calle as (
    select d.id, d.delivery_date, dl.product_code,
           dl.qty_delivered as uds,
           dl.qty_delivered * dl.unit_cost  as coste,
           dl.qty_delivered * dl.unit_price as venta,
           exists (select 1 from unnest(v_prefijos) pr where upper(dl.product_code) like pr || '%') as es_tarjeta
    from deposits d
    join deposit_lines dl on dl.deposit_id = d.id
    where d.user_id = v_uid and d.status = 'abierto'
  )
  select r || jsonb_build_object('calle', jsonb_build_object(
    'depositos', count(distinct id),
    'uds',       coalesce(sum(uds), 0),
    'tarjetas',  coalesce(sum(uds) filter (where es_tarjeta), 0),
    'coste',     round(coalesce(sum(coste), 0), 2),
    'venta',     round(coalesce(sum(venta), 0), 2),
    'por_ref', coalesce((
        select jsonb_agg(jsonb_build_object('ref', product_code, 'uds', u, 'coste', co, 'venta', ve) order by u desc)
        from (select product_code, sum(uds) u, round(sum(coste), 2) co, round(sum(venta), 2) ve
              from calle group by 1) t), '[]'::jsonb),
    'antiguedad', (
        select jsonb_agg(jsonb_build_object('tramo', tramo, 'depositos', n, 'uds', u) order by orden)
        from (
          select b.orden, b.tramo,
                 count(distinct c.id) n, coalesce(sum(c.uds), 0) u
          from (values (1, '0-30 días', 0, 30), (2, '31-60 días', 31, 60),
                       (3, '61-90 días', 61, 90), (4, 'Más de 90 días', 91, 100000)) b(orden, tramo, lo, hi)
          left join calle c on (current_date - c.delivery_date) between b.lo and b.hi
          group by b.orden, b.tramo
        ) t)
  ))
  into r
  from calle;

  -- Rotación por referencia (últimos 12 meses liquidados): % vendido de lo entregado
  r := r || jsonb_build_object('rotacion', coalesce((
    select jsonb_agg(jsonb_build_object('ref', product_code, 'entregadas', e, 'vendidas', s,
                                        'pct', round(s * 100.0 / nullif(e, 0), 1)) order by e desc)
    from (
      select dl.product_code, sum(dl.qty_delivered) e,
             sum(dl.qty_delivered - coalesce(dl.qty_remaining, 0)) s
      from deposits d
      join deposit_lines dl on dl.deposit_id = d.id
      where d.user_id = v_uid
        and d.status in ('recontado', 'facturado')
        and coalesce(d.recount_date, d.invoice_date, d.delivery_date) > (v_hasta - interval '12 months')
        and coalesce(d.recount_date, d.invoice_date, d.delivery_date) <= v_hasta
      group by 1
      having sum(dl.qty_delivered) > 0
    ) t), '[]'::jsonb));

  -- Cobros: por estado y lo pendiente por forma de pago (estado actual)
  r := r || jsonb_build_object(
    'cobros_estado', coalesce((
      select jsonb_agg(jsonb_build_object('estado', status, 'n', n, 'importe', i) order by status)
      from (select status, count(*) n, round(sum(amount), 2) i
            from pending_collections where user_id = v_uid group by 1) t), '[]'::jsonb),
    'pendiente_por_metodo', coalesce((
      select jsonb_agg(jsonb_build_object('metodo', payment_method, 'n', n, 'importe', i) order by i desc)
      from (select payment_method, count(*) n, round(sum(amount), 2) i
            from pending_collections where user_id = v_uid and status = 'pendiente' group by 1) t), '[]'::jsonb));

  -- Clientes activos visitados en el año del mes elegido
  r := r || (
    select jsonb_build_object('clientes', jsonb_build_object(
      'anio', extract(year from p_mes)::int,
      'activos', count(*),
      'visitados', count(*) filter (where exists (
          select 1 from deposits d
          where d.user_id = v_uid and d.client_id = c.id
            and (d.delivery_date between v_anio_desde and v_anio_hasta
                 or d.recount_date between v_anio_desde and v_anio_hasta)))
    ))
    from clients c
    where c.user_id = v_uid and c.is_client and c.is_active
  );

  return r;
end;
$$;

revoke all on function public.dashboard_resumen(date) from public, anon;
grant execute on function public.dashboard_resumen(date) to authenticated;

-- =====================================================================
-- Comprobación (como usuario autenticado):
--   select dashboard_resumen(current_date);
--   insert into expenses (concept, amount) values ('Gasoil', 50) returning id;
--   delete from expenses where concept = 'Gasoil' and amount = 50;  -- deshacer la prueba
-- =====================================================================
