-- =====================================================================
-- MagiluFinance · 2026-10-28 · Totales por depósito calculados en SQL
-- =====================================================================
-- Motivo: la app descargaba deposit_lines entero (y deposits, clients y
-- pending_collections) para calcular totales en el móvil. PostgREST corta
-- en "Max rows" y las URL con in.(cientos de ids) acabarán rechazadas.
--
-- Qué crea (nada más; no toca tablas, datos ni RLS):
--   1) Vista  public.v_deposit_totals  (security_invoker → respeta la RLS
--      de deposits, deposit_lines, clients y pending_collections).
--      Una fila por depósito con sus columnas + totales ya calculados.
--   2) RPC    public.kpi_recaudacion(p_hoy date)  → {hoy, mes, n}
--      para la tarjeta de Recaudación del Inicio.
--
-- Fórmula (la de recalc_daily_record):
--   vendido = qty_delivered − coalesce(qty_remaining, 0)
--   base    = vendido × unit_price
--   IVA     = base × vat_rate/100                      (solo régimen A)
--   RE      = base × 0,052 / 0,014 / 0,005 (IVA 21/10/4), solo si tiene RE
--   total   = base + IVA + RE   (sin redondear por línea)
--
-- Diferencia deliberada con recalc_daily_record: aquí, si el depósito no
-- tiene client_has_re (null), se usa la ficha del cliente, igual que hacía
-- la app y que holded_emit_invoice. recalc_daily_record usa
-- coalesce(client_has_re, false). Hoy afecta a 8 depósitos facturados del
-- 27 y 28 de mayo (7 de clientes con RE). Ver nota al final.
--
-- La app nueva NECESITA esto aplicado antes de publicar el frontend.
-- =====================================================================

create or replace view public.v_deposit_totals
with (security_invoker = true) as
select
  d.id,
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
  -- Día de la liquidación (el que usan Recaudación y la lista)
  coalesce(d.recount_date, d.invoice_date, d.delivery_date)                 as dia,
  -- RE efectivo: manda el depósito; si es null, la ficha del cliente
  coalesce(d.client_has_re, c.vat_regime = 'recargo_equivalencia', false)   as has_re,
  coalesce(t.n_lines, 0)          as n_lines,
  coalesce(t.units_delivered, 0)  as units_delivered,
  coalesce(t.units_sold, 0)       as units_sold,        -- solo líneas ya recontadas
  coalesce(t.importe_counted, 0)  as importe_counted,   -- base de las líneas ya recontadas
  coalesce(t.valor_deposito, 0)   as valor_deposito,    -- entregado × precio
  coalesce(t.base, 0)             as base,
  coalesce(t.iva, 0)              as iva,
  coalesce(t.re, 0)               as re,
  coalesce(t.base, 0) + coalesce(t.iva, 0) + coalesce(t.re, 0) as total,
  pc.status                       as collection_status  -- null = sin cobro vinculado
from public.deposits d
left join public.clients c on c.id = d.client_id
left join lateral (
  select
    count(*)                                                                   as n_lines,
    sum(dl.qty_delivered)                                                      as units_delivered,
    sum(dl.qty_delivered - dl.qty_remaining) filter (where dl.qty_remaining is not null) as units_sold,
    sum((dl.qty_delivered - dl.qty_remaining) * dl.unit_price)
      filter (where dl.qty_remaining is not null)                              as importe_counted,
    sum(dl.qty_delivered * dl.unit_price)                                      as valor_deposito,
    sum(x.base)                                                                as base,
    sum(case when coalesce(d.regime, 'A') <> 'B'
             then x.base * coalesce(dl.vat_rate, 21) / 100.0 else 0 end)       as iva,
    sum(case when coalesce(d.regime, 'A') <> 'B'
              and coalesce(d.client_has_re, c.vat_regime = 'recargo_equivalencia', false)
             then x.base * case coalesce(dl.vat_rate, 21)
                                when 21 then 0.052 when 10 then 0.014 when 4 then 0.005 else 0 end
             else 0 end)                                                       as re
  from public.deposit_lines dl
  cross join lateral (
    select (dl.qty_delivered - coalesce(dl.qty_remaining, 0)) * dl.unit_price as base
  ) x
  where dl.deposit_id = d.id
) t on true
left join lateral (
  select p.status
  from public.pending_collections p
  where p.deposit_id = d.id
  limit 1
) pc on true;

comment on view public.v_deposit_totals is
  'Una fila por depósito con totales calculados en SQL (misma fórmula que recalc_daily_record). security_invoker: respeta RLS.';

revoke all on public.v_deposit_totals from public, anon;
grant select on public.v_deposit_totals to authenticated;


-- KPI de Recaudación del Inicio: total liquidado hoy y en el mes en curso.
-- Mismo criterio que tenía la app: depósitos recontados o facturados,
-- por día de liquidación (recount_date → invoice_date → delivery_date).
create or replace function public.kpi_recaudacion(p_hoy date)
returns jsonb
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'hoy', round(coalesce(sum(v.total) filter (where v.dia = p_hoy), 0), 2),
    'mes', round(coalesce(sum(v.total), 0), 2),
    'n',   count(*)
  )
  from public.v_deposit_totals v
  where v.status in ('recontado', 'facturado')
    and v.dia >= date_trunc('month', p_hoy)::date;
$$;

revoke all on function public.kpi_recaudacion(date) from public, anon;
grant execute on function public.kpi_recaudacion(date) to authenticated;


-- =====================================================================
-- Comprobación rápida (como usuario autenticado, desde la app o el SQL
-- editor con el rol adecuado):
--   select count(*), sum(total) from v_deposit_totals where status = 'facturado';
--   select kpi_recaudacion(current_date);
--
-- NOTA (no aplicada, decide Tomás): para que el calendario
-- (recalc_daily_record) y Holded usen el mismo RE, o bien se cambia en
-- recalc_daily_record  coalesce(d.client_has_re, false)  por
--   coalesce(d.client_has_re, c.vat_regime = 'recargo_equivalencia', false)
-- (con join a clients), o bien se rellena client_has_re en esos 8 depósitos.
-- =====================================================================
