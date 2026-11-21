-- =====================================================================
-- VUELTA ATRÁS de 2026-11-21_espacios_y_forma_pago.sql
-- Solo si algo va mal: deja permisos y funciones como estaban antes.
-- (Las tablas app_spaces / app_members y deposit_set_payment se quedan, sin efecto.)
-- =====================================================================

-- Funciones: de vuelta a auth.uid()
do $mig$
declare
  f text; g text; i int;
  r text[][] := array[
    array['public.holded_emit_invoice(uuid,boolean)', 'user_id = public.current_space()', 'user_id = auth.uid()'],
    array['public.holded_send_invoice(uuid,text)',    'user_id = public.current_space()', 'user_id = auth.uid()'],
    array['public.void_signature(uuid,text)',         'user_id = public.current_space()', 'user_id = auth.uid()'],
    array['public.sign_visit(jsonb,text,text,text)',  'and user_id = public.current_space();', 'and user_id = auth.uid();'],
    array['public.sign_visit(jsonb,text,text,text)',  '(d.user_id, d.id, v_moment', '(auth.uid(), d.id, v_moment'],
    array['public.recalc_daily_record(date)',         'v_uid    uuid := public.current_space();', 'v_uid    uuid := auth.uid();'],
    array['public.holded_pay_invoice(uuid,date)',     'user_id = public.space_full_id()', 'user_id = auth.uid()'],
    array['public.holded_ping()',                     'where user_id = public.space_full_id()', 'where user_id = auth.uid()'],
    array['public.collect_pending(uuid[],date,uuid)', 'v_uid   uuid := public.space_full_id();', 'v_uid   uuid := auth.uid();'],
    array['public.mark_collections_paid(uuid[],uuid,date)', 'v_uid     uuid := public.space_full_id();', 'v_uid     uuid := auth.uid();'],
    array['public.dashboard_resumen(date)',           'v_uid    uuid := public.space_full_id();', 'v_uid    uuid := auth.uid();'],
    array['public.holded_emit_invoice(uuid,boolean)',
          ' (select '' · '' || sp.nombre from public.app_spaces sp where sp.owner_id = d.user_id and sp.orden > 1),', '']
  ];
begin
  for i in 1 .. array_length(r, 1) loop
    f := pg_get_functiondef(r[i][1]::regprocedure);
    if position(r[i][2] in f) = 0 then continue; end if;
    g := replace(f, r[i][2], r[i][3]);
    execute g;
  end loop;
end $mig$;
alter function public.recalc_daily_record(date) security invoker;

-- Triggers de espacio fuera
do $t$
declare t text;
begin
  foreach t in array array['accounts','client_locations','clients','daily_records','debts','deposit_lines',
                           'deposit_signatures','deposits','editable_data','expenses','fixed_expenses',
                           'movements','pending_collections','product_price_history','products','settings'] loop
    execute format('drop trigger if exists tr_space_user on public.%I', t);
    execute format('drop policy if exists space_all on public.%I', t);
    execute format('drop policy if exists space_select on public.%I', t);
    execute format('drop policy if exists space_insert on public.%I', t);
    execute format('drop policy if exists space_update on public.%I', t);
    execute format('drop policy if exists space_delete on public.%I', t);
    execute format('drop policy if exists space_write on public.%I', t);
  end loop;
end $t$;
drop policy if exists space_select on public.audit_log;

-- Políticas originales
create policy own_accounts on public.accounts for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy audit_read_own on public.audit_log for select to authenticated using ((select auth.uid()) = user_id);
create policy own_client_locations on public.client_locations for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_clients on public.clients for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_daily on public.daily_records for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_debts on public.debts for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy deposit_lines_delete_own on public.deposit_lines for delete using (auth.uid() = user_id);
create policy deposit_lines_insert_own on public.deposit_lines for insert with check (auth.uid() = user_id);
create policy deposit_lines_select_own on public.deposit_lines for select using (auth.uid() = user_id);
create policy deposit_lines_update_own on public.deposit_lines for update using (auth.uid() = user_id);
create policy deposit_signatures_select_own on public.deposit_signatures for select using ((select auth.uid()) = user_id);
create policy deposits_delete_own on public.deposits for delete using (auth.uid() = user_id);
create policy deposits_insert_own on public.deposits for insert with check (auth.uid() = user_id);
create policy deposits_select_own on public.deposits for select using (auth.uid() = user_id);
create policy deposits_update_own on public.deposits for update using (auth.uid() = user_id);
create policy own_editable on public.editable_data for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_expenses on public.expenses for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_expenses on public.fixed_expenses for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_movements on public.movements for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_pending on public.pending_collections for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_pph on public.product_price_history for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_products on public.products for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_settings on public.settings for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
