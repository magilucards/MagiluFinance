-- =====================================================================
-- MagiluFinance · 2026-11-21 · Costes ocultos para el colaborador (JP)
-- =====================================================================
-- Cuando JP trabaja en los depósitos de Tomás (cabecera x-mf-space + rol
-- 'depositos'), cada petición pasa al rol de Postgres «colaborador», que NO
-- puede leer los precios de coste:
--   · products.current_cost y products.reference_cost
--   · deposit_lines.unit_cost
--   · product_price_history (entera)
-- Lo decide el servidor (función previa a cada petición), así que da igual
-- desde dónde pregunte (app, Claude, un script…).
-- Tomás y JP en su propio espacio siguen con el rol de siempre: sin cambios.
-- El coste de cada línea lo pone ahora el servidor al crearla (copia del
-- coste del producto en ese momento), porque JP ya no lo puede leer.
-- =====================================================================

select extensions.urlencode('x');

-- ---------------------------------------------------------------------
-- 1) Rol «colaborador» (sin login; solo se entra desde la función previa)
-- ---------------------------------------------------------------------
do $r$ begin
  if not exists (select 1 from pg_roles where rolname = 'colaborador') then
    create role colaborador nologin noinherit;
  end if;
end $r$;
grant colaborador to authenticator;
grant usage on schema public to colaborador;

-- Tablas de Depósitos: lo mismo que puede hacer la app, salvo leer costes
grant select, insert, update on public.deposits to colaborador;
grant select, insert, update on public.pending_collections to colaborador;
grant delete on public.pending_collections to colaborador;
grant select, update on public.clients to colaborador;
grant select on public.client_locations, public.deposit_signatures, public.v_deposit_totals to colaborador;
grant insert, update, delete on public.deposit_lines to colaborador;
-- Lectura por columnas: todas menos las de coste
do $c$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'products' and column_name not in ('current_cost', 'reference_cost');
  execute format('grant select (%s) on public.products to colaborador', cols);
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'deposit_lines' and column_name <> 'unit_cost';
  execute format('grant select (%s) on public.deposit_lines to colaborador', cols);
end $c$;
-- La copia sin cobertura también pide estas: el permiso existe, pero la RLS no le da ninguna fila
grant select on public.settings, public.debts, public.fixed_expenses, public.editable_data to colaborador;

-- Funciones que usa Depósitos (y las de las políticas)
grant execute on function public.current_space(), public.space_role(), public.space_full(), public.space_full_id(),
  public.mf_spaces(), public.dep_emisor_nif(), public.deposit_set_payment(uuid, text),
  public.holded_emit_invoice(uuid, boolean), public.holded_send_invoice(uuid, text),
  public.sign_visit(jsonb, text, text, text), public.void_signature(uuid, text),
  public.recalc_daily_record(date), public.colab_mi_comision(date) to colaborador;

-- Las políticas de Depósitos valen también para «colaborador»
alter policy space_select on public.deposits           to authenticated, colaborador;
alter policy space_insert on public.deposits           to authenticated, colaborador;
alter policy space_update on public.deposits           to authenticated, colaborador;
alter policy space_delete on public.deposits           to authenticated, colaborador;
alter policy space_all    on public.deposit_lines      to authenticated, colaborador;
alter policy space_select on public.deposit_signatures to authenticated, colaborador;
alter policy space_select on public.clients            to authenticated, colaborador;
alter policy space_update on public.clients            to authenticated, colaborador;
alter policy space_select on public.client_locations   to authenticated, colaborador;
alter policy space_select on public.products           to authenticated, colaborador;
alter policy space_all    on public.pending_collections to authenticated, colaborador;

-- ---------------------------------------------------------------------
-- 2) Coste de cada línea: lo pone el servidor
-- ---------------------------------------------------------------------
create or replace function public.set_line_cost()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.product_id is distinct from old.product_id then
    new.unit_cost := coalesce((select p.current_cost from public.products p where p.id = new.product_id), 0);
  else
    new.unit_cost := old.unit_cost;   -- nadie lo cambia al editar la línea
  end if;
  return new;
end $$;
revoke all on function public.set_line_cost() from public, anon, authenticated;
drop trigger if exists tr_line_cost on public.deposit_lines;
create trigger tr_line_cost before insert or update on public.deposit_lines
  for each row execute function public.set_line_cost();

-- ---------------------------------------------------------------------
-- 3) Antes de cada petición: JP en los depósitos de otro → rol «colaborador»
-- ---------------------------------------------------------------------
create or replace function public.mf_pre_request()
returns void language plpgsql set search_path = ''
as $$
declare v_h text;
begin
  -- Sin cabecera de espacio (Tomás, JP en lo suyo, catálogo, tiendas): nada que hacer
  begin v_h := current_setting('request.headers', true)::json->>'x-mf-space';
  exception when others then v_h := null; end;
  if v_h is null or v_h = '' or current_user <> 'authenticated' then return; end if;
  if public.space_role() = 'depositos' then
    execute 'set local role colaborador';
  end if;
end $$;
grant execute on function public.mf_pre_request() to anon, authenticated;

alter role authenticator set pgrst.db_pre_request = 'public.mf_pre_request';
notify pgrst, 'reload config';
