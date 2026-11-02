-- Run this once in the Supabase SQL Editor, after schema.sql.
-- Players can read their own orders and purchases, but can never write them:
-- only the payment server (service_role) can.

create table public.products (
  id text primary key,
  name text not null,
  price_idr integer not null check (price_idr > 0),
  active boolean not null default true
);

create table public.orders (
  order_id text primary key,
  player_id uuid not null references auth.users (id) on delete restrict,
  product_id text not null references public.products (id),
  amount_idr integer not null check (amount_idr > 0),
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'paid_duplicate', 'expired', 'failed', 'refunded')),
  midtrans_transaction_id text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create index orders_player_idx on public.orders (player_id, created_at desc);

create table public.entitlements (
  player_id uuid not null references auth.users (id) on delete cascade,
  product_id text not null references public.products (id),
  order_id text not null references public.orders (order_id),
  granted_at timestamptz not null default now(),
  primary key (player_id, product_id)
);

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.entitlements enable row level security;

create policy "Anyone can see products" on public.products
  for select to anon, authenticated using (active);
create policy "Players see their own orders" on public.orders
  for select to authenticated using (auth.uid() = player_id);
create policy "Players see their own purchases" on public.entitlements
  for select to authenticated using (auth.uid() = player_id);

revoke all on public.products, public.orders, public.entitlements from anon, authenticated;
grant select on public.products to anon, authenticated;
grant select on public.orders, public.entitlements to authenticated;

-- The one place money turns into items. It runs as a single transaction, and is
-- safe to call repeatedly with the same notification. Returns what happened.
create function public.apply_payment(p_order_id text, p_status text, p_transaction_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.orders%rowtype;
  inserted integer;
begin
  select * into target from public.orders where order_id = p_order_id for update;
  if not found then
    return 'unknown_order';
  end if;

  if p_status = 'paid' then
    if target.status in ('paid', 'paid_duplicate', 'refunded') then
      return 'no_change';
    end if;
    insert into public.entitlements (player_id, product_id, order_id)
      values (target.player_id, target.product_id, target.order_id)
      on conflict (player_id, product_id) do nothing;
    get diagnostics inserted = row_count;
    update public.orders
      set status = case when inserted = 1 then 'paid' else 'paid_duplicate' end,
          paid_at = now(),
          midtrans_transaction_id = p_transaction_id
      where order_id = p_order_id;
    return case when inserted = 1 then 'granted' else 'duplicate' end;
  elsif p_status = 'refunded' then
    delete from public.entitlements where order_id = p_order_id;
    update public.orders set status = 'refunded' where order_id = p_order_id;
    return 'refunded';
  elsif p_status in ('expired', 'failed') then
    update public.orders set status = p_status
      where order_id = p_order_id and status = 'pending';
    return 'closed';
  end if;
  return 'no_change';
end;
$$;

revoke all on function public.apply_payment(text, text, text) from public, anon, authenticated;
grant execute on function public.apply_payment(text, text, text) to service_role;

-- Starter products. Change names and prices here; the game reads them from the table.
insert into public.products (id, name, price_idr) values
  ('skin_engineer', 'Engineer crew member', 15000),
  ('skin_medic', 'Medic crew member', 15000),
  ('skin_pilot', 'Pilot crew member', 15000);
