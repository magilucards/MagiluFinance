-- =====================================================================
-- MagiluFinance · 2026-11-03 · Marcar uno o varios cobros como cobrados
-- =====================================================================
-- collect_pending(p_ids, p_date, p_account_id) hace en el servidor, de una
-- vez y todo o nada, lo que antes hacía la app paso a paso por cada cobro:
--   1. un movimiento de ingreso en la cuenta elegida (uno por cobro, con el
--      mismo concepto de siempre: "Cobro <forma> · <cliente> (fact <fecha>)"),
--   2. el cobro pasa a «cobrado» con su fecha, cuenta y movimiento,
--   3. el saldo de la cuenta sube en la suma de todos (una sola vez).
-- Si algo falla a mitad, no se aplica nada. Los cobros que ya no estén
-- pendientes (cobrados desde otro sitio) se saltan y se cuentan en «omitidos».
-- Holded se sigue avisando desde la app, cobro a cobro, como hasta ahora.
--
-- security invoker: se aplican las políticas RLS del usuario.
-- =====================================================================

create or replace function public.collect_pending(p_ids uuid[], p_date date, p_account_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid   uuid := auth.uid();
  v_total numeric := 0;
  v_done  jsonb := '[]'::jsonb;
  v_pedidos integer;
  v_mov   uuid;
  r       record;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  if p_date is null then raise exception 'Falta la fecha de cobro'; end if;
  if p_account_id is null then raise exception 'Falta la cuenta de destino'; end if;
  if p_ids is null or cardinality(p_ids) = 0 then raise exception 'No hay cobros seleccionados'; end if;
  if cardinality(p_ids) > 500 then raise exception 'Demasiados cobros a la vez (máximo 500)'; end if;

  select count(distinct x) into v_pedidos from unnest(p_ids) x;

  -- La cuenta tiene que ser del usuario; queda bloqueada hasta terminar
  perform 1 from accounts where id = p_account_id and user_id = v_uid for update;
  if not found then raise exception 'Cuenta de destino no encontrada'; end if;

  -- Solo los que sigan pendientes; bloqueados para que nadie los cobre a la vez
  for r in
    select id, deposit_id, amount, payment_method, client_name, invoice_date
    from pending_collections
    where id = any(p_ids) and user_id = v_uid and status = 'pendiente'
    order by invoice_date, id
    for update
  loop
    insert into movements (user_id, mov_date, mov_type, dest_account_id, amount, concept)
    values (v_uid, p_date, 'ingreso', p_account_id, r.amount,
            'Cobro ' || r.payment_method || coalesce(' · ' || r.client_name, '') || ' (fact ' || r.invoice_date || ')')
    returning id into v_mov;

    update pending_collections
       set status = 'cobrado',
           collected_date = p_date,
           collected_account_id = p_account_id,
           collected_movement_id = v_mov
     where id = r.id;

    v_total := v_total + r.amount;
    v_done := v_done || jsonb_build_object('id', r.id, 'deposit_id', r.deposit_id,
                                           'amount', r.amount, 'client_name', r.client_name);
  end loop;

  if v_total > 0 then
    update accounts set balance = coalesce(balance, 0) + v_total where id = p_account_id;
  end if;

  return jsonb_build_object(
    'n',        jsonb_array_length(v_done),
    'total',    round(v_total, 2),
    'omitidos', v_pedidos - jsonb_array_length(v_done),
    'cobrados', v_done
  );
end;
$$;

revoke all on function public.collect_pending(uuid[], date, uuid) from public, anon;
grant execute on function public.collect_pending(uuid[], date, uuid) to authenticated;
