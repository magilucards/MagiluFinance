-- =====================================================================
-- MagiluFinance · 2026-10-28 · Calendario: el RE se decide igual que Holded
-- =====================================================================
-- Antes: recalc_daily_record usaba coalesce(client_has_re, false), así que
-- un depósito sin la casilla RE marcada se calculaba SIN recargo aunque el
-- cliente fuera de recargo de equivalencia. Holded (holded_emit_invoice) sí
-- mira la ficha del cliente. Manda Holded.
--
-- Ahora: coalesce(client_has_re, cliente con recargo_equivalencia, false),
-- igual que holded_emit_invoice y que v_deposit_totals.
--
-- No cambia datos. Comprobado antes de aplicar: con la fórmula nueva, 61 de
-- 63 días facturados coinciden al céntimo con daily_records (incluidos 27 y
-- 28 de mayo, que con la fórmula vieja perdían el RE si se recalculaban).
-- Los 2 restantes (2 y 29 de julio) son históricos y no se tocan.
-- =====================================================================

create or replace function public.recalc_daily_record(p_date date)
returns jsonb
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_a      numeric := 0;
  v_b      numeric := 0;
  v_exists boolean;
begin
  if v_uid is null then
    raise exception 'No autenticado';
  end if;
  if p_date is null then
    raise exception 'Falta la fecha';
  end if;

  -- Solo depósitos facturados con esa fecha de factura.
  -- A = vendido x precio x (1 + IVA + RE si el cliente tiene RE). B = vendido x precio.
  -- RE: manda la casilla del depósito; si está vacía, la ficha del cliente (igual que Holded).
  select
    round(coalesce(sum(t) filter (where regime = 'A'), 0), 2),
    round(coalesce(sum(t) filter (where regime = 'B'), 0), 2)
  into v_a, v_b
  from (
    select d.regime,
           (dl.qty_delivered - coalesce(dl.qty_remaining, 0)) * dl.unit_price *
           case when d.regime = 'A' then
                  1 + coalesce(dl.vat_rate, 21) / 100.0
                    + case when coalesce(d.client_has_re, c.vat_regime = 'recargo_equivalencia', false) then
                             case coalesce(dl.vat_rate, 21) when 21 then 0.052 when 10 then 0.014 when 4 then 0.005 else 0 end
                           else 0 end
                else 1 end as t
    from public.deposits d
    join public.deposit_lines dl on dl.deposit_id = d.id
    left join public.clients c on c.id = d.client_id
    where d.user_id = v_uid
      and d.status = 'facturado'
      and d.invoice_date = p_date
  ) x;

  select exists (
    select 1 from public.daily_records where user_id = v_uid and record_date = p_date
  ) into v_exists;

  -- Día sin facturación y sin registro: no se crea nada
  if v_a = 0 and v_b = 0 and not v_exists then
    return jsonb_build_object('record_date', p_date, 'invoiced_a', 0, 'invoiced_b', 0, 'action', 'none');
  end if;

  insert into public.daily_records (user_id, record_date, invoiced_a, invoiced_b)
  values (v_uid, p_date, v_a, v_b)
  on conflict (user_id, record_date)
  do update set invoiced_a = excluded.invoiced_a,
                invoiced_b = excluded.invoiced_b;

  return jsonb_build_object(
    'record_date', p_date,
    'invoiced_a', v_a,
    'invoiced_b', v_b,
    'action', case when v_exists then 'updated' else 'created' end
  );
end;
$function$;
