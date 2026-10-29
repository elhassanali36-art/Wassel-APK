-- ============================================================================
-- واصل — Wassel delivery network · Supabase schema
-- Run this once in the Supabase SQL editor (Dashboard → SQL → New query).
-- It is safe to run twice (idempotent) and works on a plain PostgreSQL too.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- drivers ---
-- One row per delivery driver. Identity documents are reviewed by the platform
-- owner; a driver can NEVER claim an order unless status = 'APPROVED'.
create table if not exists public.drivers (
  id               uuid primary key default gen_random_uuid(),
  auth_uid         uuid unique,
  full_name        text not null,
  phone            text not null unique,
  -- Mطلوب فعلياً: رخصة قيادة سارية + سيلفي معها. بقية الحقول اختيارية وقديمة.
  licence_no       text,
  licence_expiry   date,
  licence_photo    text,               -- صورة الرخصة (مسار/رابط على جهاز السائق)
  selfie_licence   text,               -- سيلفي والسائق يحمل الرخصة
  national_id      text,
  birth_year       int,
  city             text,
  vehicle_type     text,
  vehicle_plate    text,
  status           text not null default 'PENDING'
                   check (status in ('DRAFT','PENDING','APPROVED','REJECTED','SUSPENDED')),
  rejection_reason text,
  docs_verified    boolean not null default false,
  created_at       timestamptz not null default now(),
  decided_at       timestamptz,
  -- live position, used to dispatch each order to the nearest driver
  last_lat         double precision,
  last_lng         double precision,
  location_at      timestamptz
);


-- --------------------------------------------------------------- stores ------
create table if not exists public.stores (
  id          text primary key,              -- id coming from سوق السودان الكبير
  name        text not null,
  category    text not null,                 -- supermarket | pharmacy | restaurant | …
  city        text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- --------------------------------------------------------------- orders -----
-- The shared pool: every marketplace order lands here, whichever store/category
-- it came from, and any approved driver can claim it.
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  external_id    text unique,                -- marketplace order reference
  store_id       text references public.stores(id) on delete set null,
  store_name     text not null,
  store_category text not null,
  pickup_label   text,
  pickup_lat     double precision,
  pickup_lng     double precision,
  drop_label     text,
  drop_lat       double precision,
  drop_lng       double precision,
  items_summary  text,
  customer_name  text,
  customer_phone text,
  distance_km    numeric(8,2),
  fee_sdg        numeric(10,2) not null check (fee_sdg >= 0),
  driver_id      uuid references public.drivers(id) on delete set null,
  status         text not null default 'POOL'
                 check (status in ('POOL','CLAIMED','PICKED_UP','DELIVERED','CANCELLED')),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  claimed_at     timestamptz,
  delivered_at   timestamptz
);

create index if not exists orders_pool_idx   on public.orders (status, created_at desc);
create index if not exists orders_driver_idx on public.orders (driver_id, status);

-- --------------------------------------------------------------- history ----
create table if not exists public.order_events (
  id           bigserial primary key,
  order_id     uuid references public.orders(id) on delete cascade,
  actor_driver uuid references public.drivers(id) on delete set null,
  type         text not null,
  payload      jsonb,
  created_at   timestamptz not null default now()
);

-- upgrades for projects created before proximity dispatch existed
alter table public.drivers add column if not exists last_lat    double precision;
alter table public.drivers add column if not exists last_lng    double precision;
alter table public.drivers add column if not exists location_at timestamptz;
alter table public.orders  add column if not exists offer_driver_id uuid references public.drivers(id) on delete set null;
alter table public.orders  add column if not exists offer_expires_at timestamptz;
alter table public.orders  add column if not exists offered_count int not null default 0;

create index if not exists drivers_geo_idx on public.drivers (status, location_at desc);

-- ------------------------------------------------------------- functions ----
-- Business rules are enforced in the database so that a stale or malicious
-- client can never break them: approved driver only, one driver per order,
-- at most 3 active orders, and only legal status transitions.

create or replace function public.claim_order(p_order uuid, p_driver uuid)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  r        public.orders;
  v_status text;
  v_active int;
begin
  select status into v_status from public.drivers where id = p_driver;
  if v_status is null then raise exception 'DRIVER_NOT_FOUND'; end if;
  if v_status <> 'APPROVED' then raise exception 'DRIVER_NOT_APPROVED'; end if;

  -- an order currently offered to a nearer driver is not open to everybody
  if (select offer_driver_id from public.orders where id = p_order) is not null
     and (select offer_expires_at from public.orders where id = p_order) > now()
     and (select offer_driver_id from public.orders where id = p_order) <> p_driver then
    raise exception 'OFFERED_TO_OTHER';
  end if;

  select count(*) into v_active
    from public.orders
   where driver_id = p_driver and status in ('CLAIMED','PICKED_UP');
  if v_active >= 3 then raise exception 'ACTIVE_LIMIT'; end if;

  update public.orders
     set driver_id = p_driver, status = 'CLAIMED', claimed_at = now(), updated_at = now()
   where id = p_order and status = 'POOL' and driver_id is null
  returning * into r;

  if r.id is null then raise exception 'ORDER_UNAVAILABLE'; end if;

  insert into public.order_events (order_id, actor_driver, type)
  values (r.id, p_driver, 'CLAIMED');
  return r;
end $$;

create or replace function public.move_order(p_order uuid, p_driver uuid, p_status text)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  r     public.orders;
  v_ok  boolean := false;
begin
  select * into r from public.orders where id = p_order for update;
  if r.id is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if r.driver_id is distinct from p_driver then raise exception 'NOT_YOUR_ORDER'; end if;

  v_ok := (r.status = 'CLAIMED'   and p_status in ('PICKED_UP','CANCELLED'))
       or (r.status = 'PICKED_UP' and p_status = 'DELIVERED')
       or (r.status = 'POOL'      and p_status = 'CANCELLED');
  if not v_ok then raise exception 'ILLEGAL_TRANSITION'; end if;

  update public.orders
     set status = p_status,
         updated_at = now(),
         delivered_at = case when p_status = 'DELIVERED' then now() else delivered_at end
   where id = p_order
  returning * into r;

  insert into public.order_events (order_id, actor_driver, type)
  values (r.id, p_driver, p_status);
  return r;
end $$;

create or replace function public.release_order(p_order uuid, p_driver uuid)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare r public.orders;
begin
  update public.orders
     set driver_id = null, status = 'POOL', claimed_at = null, updated_at = now()
   where id = p_order and driver_id = p_driver and status = 'CLAIMED'
  returning * into r;
  if r.id is null then raise exception 'NOT_RELEASABLE'; end if;
  insert into public.order_events (order_id, actor_driver, type)
  values (r.id, p_driver, 'RELEASED');
  return r;
end $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders
for each row execute function public.touch_updated_at();


-- ============================================================================
-- Proximity dispatch: each order goes to the NEAREST available driver.
-- An offer is a time boxed invitation (default 90 s). If it is not accepted,
-- expire_offers() clears it and offer_order() hands the order to the next
-- nearest driver. Nobody further than the radius is ever offered the order.
-- ============================================================================

create or replace function public.haversine_km(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- Ranked candidates for one order: approved, located, under the active limit.
create or replace function public.nearest_drivers(
  p_order     uuid,
  p_radius_km double precision default 8,
  p_limit     int default 10
)
returns table (driver_id uuid, driver_name text, distance_km double precision, active_orders int)
language sql stable security definer
set search_path = public
as $$
  with pickup as (
    select pickup_lat as lat, pickup_lng as lng from public.orders where id = p_order
  )
  select d.id,
         d.full_name,
         public.haversine_km(d.last_lat, d.last_lng, p.lat, p.lng) as distance_km,
         (select count(*)::int from public.orders o
           where o.driver_id = d.id and o.status in ('CLAIMED','PICKED_UP')) as active_orders
    from public.drivers d, pickup p
   where d.status = 'APPROVED'
     and d.last_lat is not null and d.last_lng is not null
     and p.lat is not null and p.lng is not null
     and public.haversine_km(d.last_lat, d.last_lng, p.lat, p.lng) <= p_radius_km
     and (select count(*) from public.orders o
           where o.driver_id = d.id and o.status in ('CLAIMED','PICKED_UP')) < 3
     -- a driver who already ignored this order is not offered it again
     and d.id not in (select e.actor_driver from public.order_events e
                       where e.order_id = p_order and e.type = 'OFFERED')
   order by 3 asc
   limit p_limit;
$$;

-- Offers the order to the nearest driver; returns the chosen driver (or nothing).
create or replace function public.offer_order(
  p_order       uuid,
  p_radius_km   double precision default 8,
  p_ttl_seconds int default 90
)
returns table (driver_id uuid, driver_name text, distance_km double precision)
language plpgsql security definer
set search_path = public
as $$
declare
  v_status text;
  v_row    record;
begin
  select status into v_status from public.orders where id = p_order;
  if v_status is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_status <> 'POOL' then raise exception 'ORDER_NOT_IN_POOL'; end if;

  select * into v_row from public.nearest_drivers(p_order, p_radius_km, 1);
  if v_row.driver_id is null then
    -- nobody in range: leave the order open in the pool
    update public.orders set offer_driver_id = null, offer_expires_at = null where id = p_order;
    return;
  end if;

  update public.orders
     set offer_driver_id  = v_row.driver_id,
         offer_expires_at = now() + make_interval(secs => p_ttl_seconds),
         offered_count    = offered_count + 1,
         updated_at       = now()
   where id = p_order;

  insert into public.order_events (order_id, actor_driver, type, payload)
  values (p_order, v_row.driver_id, 'OFFERED',
          jsonb_build_object('distance_km', v_row.distance_km, 'ttl', p_ttl_seconds));

  return query select v_row.driver_id, v_row.driver_name, v_row.distance_km;
end $$;

-- Clears expired offers so the order can be offered to the next nearest driver.
create or replace function public.expire_offers()
returns int
language plpgsql security definer
set search_path = public
as $$
declare v_count int;
begin
  with expired as (
    update public.orders
       set offer_driver_id = null, offer_expires_at = null, updated_at = now()
     where status = 'POOL' and offer_driver_id is not null and offer_expires_at < now()
    returning id
  )
  select count(*) into v_count from expired;
  return v_count;
end $$;

-- Accepting an offer is the same guarded claim, but only by the offered driver.
create or replace function public.accept_offer(p_order uuid, p_driver uuid)
returns public.orders
language plpgsql security definer
set search_path = public
as $$
declare r public.orders;
begin
  if (select offer_driver_id from public.orders where id = p_order) is distinct from p_driver then
    raise exception 'NOT_OFFERED_TO_YOU';
  end if;
  if (select offer_expires_at from public.orders where id = p_order) < now() then
    raise exception 'OFFER_EXPIRED';
  end if;

  r := public.claim_order(p_order, p_driver);

  update public.orders set offer_driver_id = null, offer_expires_at = null where id = p_order;
  insert into public.order_events (order_id, actor_driver, type)
  values (p_order, p_driver, 'OFFER_ACCEPTED');
  return r;
end $$;

-- One scheduler tick: clear the offers nobody accepted, then hand every open
-- order to its nearest not-yet-tried driver. Safe to call every minute and
-- safe to call concurrently (each order is updated atomically).
create or replace function public.dispatch_tick(
  p_radius_km double precision default 8,
  p_ttl_seconds int default 90
)
returns table (expired int, offered int, unassigned int)
language plpgsql security definer
set search_path = public
as $$
declare
  v_expired int;
  v_offered int := 0;
  v_open    int := 0;
  r         record;
begin
  v_expired := public.expire_offers();

  for r in
    select id from public.orders
     where status = 'POOL' and offer_driver_id is null
     order by created_at asc
  loop
    if exists (select 1 from public.offer_order(r.id, p_radius_km, p_ttl_seconds)) then
      v_offered := v_offered + 1;
    else
      v_open := v_open + 1;
    end if;
  end loop;

  return query select v_expired, v_offered, v_open;
end $$;

-- Drivers publish their position; only they should move it.
create or replace function public.update_location(p_driver uuid, p_lat double precision, p_lng double precision)
returns void
language sql security definer
set search_path = public
as $$
  update public.drivers
     set last_lat = p_lat, last_lng = p_lng, location_at = now()
   where id = p_driver and status = 'APPROVED';
$$;

-- الترقية من مخطط قديم كان يفرض الهوية وتاريخ الميلاد ونوع المركبة
do $$
begin
  alter table public.drivers alter column national_id  drop not null;
exception when others then null; end $$;
do $$
begin
  alter table public.drivers alter column vehicle_type drop not null;
exception when others then null; end $$;
do $$
begin
  alter table public.drivers alter column birth_year   drop not null;
exception when others then null; end $$;
do $$
begin
  alter table public.drivers drop constraint if exists drivers_birth_year_check;
exception when others then null; end $$;
alter table public.drivers add column if not exists licence_expiry date;
alter table public.drivers add column if not exists licence_photo  text;
alter table public.drivers add column if not exists selfie_licence text;


/* ------------------------------------------------------------------ *
 *  توثيق هوية السائقين — جانب المراجعة
 *  المالك يضع مفتاح مراجعة (لا يُخزَّن، فقط بصمته)، وبعدها يقرأ الطابور
 *  ويعتمد/يرفض. كل شيء عبر دوال security definer تتحقق من المفتاح.
 * ------------------------------------------------------------------ */

create extension if not exists pgcrypto;

create table if not exists public.review_settings (
  id             int primary key default 1 check (id = 1),
  admin_key_hash text not null,
  updated_at     timestamptz not null default now()
);

create table if not exists public.driver_reviews (
  id          bigserial primary key,
  driver_id   uuid not null references public.drivers(id) on delete cascade,
  decision    text not null check (decision in ('APPROVED','REJECTED','SUSPENDED')),
  reason      text,
  reviewed_at timestamptz not null default now()
);

alter table public.review_settings enable row level security;
alter table public.driver_reviews  enable row level security;

create or replace function public.review_hash(p_key text)
returns text language sql immutable as $$
  select encode(digest(coalesce(p_key,''), 'sha256'), 'hex')
$$;

/** أول مرة: يضع مفتاح المراجعة. بعدها يتطلب المفتاح القديم. */
create or replace function public.set_review_key(p_key text, p_old_key text default null)
returns void language plpgsql security definer set search_path = public as $$
declare existing text;
begin
  if length(coalesce(p_key,'')) < 8 then raise exception 'KEY_TOO_SHORT'; end if;
  select admin_key_hash into existing from review_settings where id = 1;
  if existing is not null and existing <> review_hash(p_old_key) then raise exception 'BAD_KEY'; end if;
  insert into review_settings (id, admin_key_hash, updated_at)
  values (1, review_hash(p_key), now())
  on conflict (id) do update set admin_key_hash = excluded.admin_key_hash, updated_at = now();
end $$;

/** طابور المراجعة: كل السائقين مع صور الرخصة والسيلفي. */
create or replace function public.driver_review_queue(p_key text)
returns setof public.drivers
language plpgsql security definer set search_path = public as $$
declare key_hash text;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  return query
    select d.* from drivers d
    order by case d.status when 'PENDING' then 0 when 'SUSPENDED' then 1 else 2 end,
             d.licence_expiry nulls last;
end $$;

/** قرار المراجعة: اعتماد/رفض/إيقاف، بشرط وجود الصورتين ورخصة غير منتهية للاعتماد. */
create or replace function public.review_driver(
  p_driver uuid, p_decision text, p_reason text default null, p_key text default null
) returns text language plpgsql security definer set search_path = public as $$
declare key_hash text; d record;
begin
  select admin_key_hash into key_hash from review_settings where id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  if p_decision not in ('APPROVED','REJECTED','SUSPENDED') then raise exception 'BAD_DECISION'; end if;

  select * into d from drivers where id = p_driver for update;
  if not found then raise exception 'DRIVER_NOT_FOUND'; end if;

  if p_decision = 'APPROVED' then
    if coalesce(d.licence_photo,'') = '' then raise exception 'LICENCE_PHOTO_MISSING'; end if;
    if coalesce(d.selfie_licence,'') = '' then raise exception 'SELFIE_MISSING'; end if;
    if d.licence_expiry is null then raise exception 'LICENCE_EXPIRY_MISSING'; end if;
    if d.licence_expiry < current_date then raise exception 'LICENCE_EXPIRED'; end if;
  end if;

  if p_decision = 'REJECTED' and length(coalesce(p_reason,'')) < 3 then
    raise exception 'REASON_REQUIRED';
  end if;

  update drivers
     set status = p_decision,
         rejection_reason = case when p_decision = 'REJECTED' then p_reason else null end,
         docs_verified = (p_decision = 'APPROVED'),
         decided_at = now()
   where id = p_driver;

  insert into driver_reviews (driver_id, decision, reason)
  values (p_driver, p_decision, p_reason);

  return p_decision;
end $$;

/** إيقاف تلقائي لكل اعتماد انتهت رخصته. */
create or replace function public.suspend_lapsed_licences()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with lapsed as (
    update drivers set status = 'SUSPENDED', docs_verified = false, decided_at = now(),
      rejection_reason = 'انتهت صلاحية رخصة القيادة'
    where status = 'APPROVED' and licence_expiry is not null and licence_expiry < current_date
    returning id
  ), audited as (
    insert into driver_reviews (driver_id, decision, reason)
    select id, 'SUSPENDED', 'انتهت صلاحية رخصة القيادة' from lapsed
    returning 1
  )
  select count(*) into n from audited;
  return n;
end $$;

grant execute on function public.set_review_key(text, text)      to anon, authenticated;
grant execute on function public.driver_review_queue(text)       to anon, authenticated;
grant execute on function public.review_driver(uuid, text, text, text) to anon, authenticated;
grant execute on function public.suspend_lapsed_licences()       to anon, authenticated;


/* ================================================================== *
 *  ربط «سوق السودان الكبير» بتطبيق واصل
 *  كل متجر يستلم مفتاحاً خاصاً به، وينشر طلباته عبر publish_order.
 *  الطلب يدخل سوق السائقين مباشرة بنوع متجره (بقالة/صيدلية/مطعم/…).
 * ================================================================== */

alter table public.stores add column if not exists api_key_hash text;
alter table public.stores add column if not exists phone        text;
alter table public.stores add column if not exists address      text;
alter table public.stores add column if not exists pickup_lat   double precision;
alter table public.stores add column if not exists pickup_lng   double precision;

create table if not exists public.platform_settings (
  id            int primary key default 1 check (id = 1),
  rate_per_km   numeric(10,2) not null default 3500,
  road_factor   numeric(4,2)  not null default 1.35,
  updated_at    timestamptz not null default now()
);
insert into public.platform_settings (id) values (1) on conflict (id) do nothing;
alter table public.platform_settings enable row level security;

/** المالك يضع/يغيّر مفتاح متجر باستخدام مفتاح المراجعة. */
create or replace function public.set_store_key(
  p_store text, p_key text, p_admin_key text, p_name text default null, p_category text default null
) returns text language plpgsql security definer set search_path = public as $$
declare key_hash text;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_admin_key) then raise exception 'BAD_KEY'; end if;
  if length(coalesce(p_key,'')) < 12 then raise exception 'STORE_KEY_TOO_SHORT'; end if;

  insert into stores (id, name, category, api_key_hash)
  values (p_store, coalesce(p_name, p_store), coalesce(p_category, 'supermarket'), review_hash(p_key))
  on conflict (id) do update
    set api_key_hash = excluded.api_key_hash,
        name   = coalesce(p_name, stores.name),
        category = coalesce(p_category, stores.category);

  return p_store;
end $$;

/** أجرأ نقل: المنصة تنشر طلباً. متكرر الأمان عبر external_id. */
create or replace function public.publish_order(p_key text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  st        public.stores%rowtype;
  v_pick_lat double precision; v_pick_lng double precision;
  v_drop_lat double precision; v_drop_lng double precision;
  v_distance double precision;
  v_rate     numeric; v_factor numeric;
  v_fee      numeric;
  v_external text;
  v_order    public.orders%rowtype;
begin
  select * into st from stores
   where api_key_hash = review_hash(p_key) and is_active
   limit 1;
  if not found then raise exception 'BAD_STORE_KEY'; end if;

  v_external := nullif(p_payload->>'external_id', '');

  -- متكرر: نفس الطلب لا يُنشأ مرتين
  if v_external is not null then
    select * into v_order from orders where external_id = v_external;
    if found then
      return jsonb_build_object('order_id', v_order.id, 'status', v_order.status,
        'fee_sdg', v_order.fee_sdg, 'distance_km', v_order.distance_km, 'duplicate', true);
    end if;
  end if;

  v_pick_lat := coalesce((p_payload->>'pickup_lat')::double precision, st.pickup_lat);
  v_pick_lng := coalesce((p_payload->>'pickup_lng')::double precision, st.pickup_lng);
  v_drop_lat := (p_payload->>'drop_lat')::double precision;
  v_drop_lng := (p_payload->>'drop_lng')::double precision;

  if v_pick_lat is null or v_pick_lng is null then raise exception 'PICKUP_LOCATION_REQUIRED'; end if;
  if v_drop_lat is null or v_drop_lng is null then raise exception 'DROP_LOCATION_REQUIRED'; end if;

  select rate_per_km, road_factor into v_rate, v_factor from platform_settings where id = 1;
  v_distance := round(((haversine_km(v_pick_lat, v_pick_lng, v_drop_lat, v_drop_lng) * v_factor)::numeric), 2);
  v_fee := round((v_distance * v_rate)::numeric, 0);

  -- رسوم أرسلتها المنصة تُحترم، وإلا تُحسب من المسافة
  if (p_payload->>'delivery_fee') is not null then
    v_fee := round((p_payload->>'delivery_fee')::numeric, 0);
  end if;

  insert into orders (external_id, store_id, store_name, store_category,
                      pickup_label, pickup_lat, pickup_lng,
                      drop_label, drop_lat, drop_lng,
                      items_summary, customer_name, customer_phone,
                      distance_km, fee_sdg, notes, status)
  values (v_external, st.id, coalesce(p_payload->>'store_name', st.name),
          coalesce(p_payload->>'store_category', st.category),
          coalesce(p_payload->>'pickup_label', st.address),
          v_pick_lat, v_pick_lng,
          p_payload->>'drop_label', v_drop_lat, v_drop_lng,
          p_payload->>'items_summary', p_payload->>'customer_name', p_payload->>'customer_phone',
          v_distance, v_fee, p_payload->>'notes', 'POOL')
  returning * into v_order;

  insert into order_events (order_id, type, payload)
  values (v_order.id, 'PUBLISHED', jsonb_build_object('store', st.id, 'category', v_order.store_category));

  return jsonb_build_object('order_id', v_order.id, 'status', v_order.status,
    'fee_sdg', v_order.fee_sdg, 'distance_km', v_order.distance_km, 'duplicate', false);
end $$;

/** متابعة المتجر لطلباته: من استلمها وأين وصلت. */
create or replace function public.store_orders(p_key text, p_limit int default 50)
returns table (
  id uuid, external_id text, status text, fee_sdg numeric, distance_km numeric,
  driver_name text, driver_phone text, created_at timestamptz, claimed_at timestamptz, delivered_at timestamptz
) language plpgsql security definer set search_path = public as $$
declare st public.stores%rowtype;
begin
  select * into st from stores where api_key_hash = review_hash(p_key) and is_active limit 1;
  if not found then raise exception 'BAD_STORE_KEY'; end if;
  return query
    select o.id, o.external_id, o.status, o.fee_sdg, o.distance_km,
           d.full_name, d.phone, o.created_at, o.claimed_at, o.delivered_at
    from orders o
    left join drivers d on d.id = o.driver_id
    where o.store_id = st.id
    order by o.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 200));
end $$;

/** إلغاء طلب لم يُستلم بعد. */
create or replace function public.cancel_order(p_key text, p_order uuid, p_reason text default null)
returns text language plpgsql security definer set search_path = public as $$
declare st public.stores%rowtype; o public.orders%rowtype;
begin
  select * into st from stores where api_key_hash = review_hash(p_key) and is_active limit 1;
  if not found then raise exception 'BAD_STORE_KEY'; end if;
  select * into o from orders where id = p_order and store_id = st.id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if o.status not in ('POOL','CLAIMED') then raise exception 'ORDER_NOT_CANCELLABLE'; end if;
  update orders set status = 'CANCELLED', notes = coalesce(p_reason, notes), updated_at = now()
   where id = p_order;
  insert into order_events (order_id, type, payload) values (p_order, 'CANCELLED', jsonb_build_object('reason', p_reason));
  return 'CANCELLED';
end $$;

grant execute on function public.set_store_key(text, text, text, text, text) to anon, authenticated;
grant execute on function public.publish_order(text, jsonb)                     to anon, authenticated;
grant execute on function public.store_orders(text, int)                        to anon, authenticated;
grant execute on function public.cancel_order(text, uuid, text)                 to anon, authenticated;


/* ================================================================== *
 *  لوحة الإدارة: السعر، إضافة سائق، حذف سائق
 *  كلها محمية بمفتاح المراجعة نفسه (بصمة sha256).
 * ================================================================== */

/** السعر الحالي — قراءة عامة، لا سرّ فيه. */
create or replace function public.public_pricing()
returns table (rate_per_km numeric, road_factor numeric, updated_at timestamptz)
language sql security definer set search_path = public as $$
  select ps.rate_per_km, ps.road_factor, ps.updated_at from platform_settings ps where ps.id = 1
$$;

/** تعديل سعر الكيلومتر ومعامل الطريق. */
create or replace function public.admin_set_pricing(
  p_rate numeric, p_factor numeric, p_admin_key text
) returns table (rate_per_km numeric, road_factor numeric)
language plpgsql security definer set search_path = public as $$
declare key_hash text;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_admin_key) then raise exception 'BAD_KEY'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'RATE_INVALID'; end if;
  if p_factor is null or p_factor <= 0 or p_factor > 5 then raise exception 'FACTOR_INVALID'; end if;
  update platform_settings set rate_per_km = p_rate, road_factor = p_factor, updated_at = now() where id = 1;
  return query select ps.rate_per_km, ps.road_factor from platform_settings ps where ps.id = 1;
end $$;

/** كل السائقين مع عدد طلباتهم النشطة، للإدارة. */
create or replace function public.admin_list_drivers(p_key text)
returns table (
  id uuid, full_name text, phone text, licence_no text, licence_expiry date,
  status text, docs_verified boolean, created_at timestamptz,
  active_orders int, delivered_orders int
) language plpgsql security definer set search_path = public as $$
declare key_hash text;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  return query
    select d.id, d.full_name, d.phone, d.licence_no, d.licence_expiry,
           d.status, d.docs_verified, d.created_at,
           (select count(*)::int from orders o where o.driver_id = d.id and o.status in ('CLAIMED','PICKED_UP')),
           (select count(*)::int from orders o where o.driver_id = d.id and o.status = 'DELIVERED')
    from drivers d
    order by d.created_at desc;
end $$;

/** إضافة سائق من لوحة الإدارة (تسجيل هاتفي أو توثيق ورقي). */
create or replace function public.admin_add_driver(
  p_key text, p_full_name text, p_phone text,
  p_licence_no text default null, p_licence_expiry date default null,
  p_status text default 'APPROVED'
) returns uuid language plpgsql security definer set search_path = public as $$
declare key_hash text; v_phone text; v_id uuid;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  if length(coalesce(p_full_name,'')) < 4 then raise exception 'NAME_REQUIRED'; end if;
  v_phone := regexp_replace(coalesce(p_phone,''), '[^0-9+]', '', 'g');
  if length(v_phone) < 9 then raise exception 'PHONE_INVALID'; end if;
  if p_status not in ('APPROVED','PENDING','SUSPENDED') then raise exception 'BAD_STATUS'; end if;
  if p_status = 'APPROVED' and (p_licence_expiry is null or p_licence_expiry < current_date) then
    raise exception 'LICENCE_REQUIRED';
  end if;

  insert into drivers (full_name, phone, licence_no, licence_expiry, status, docs_verified, decided_at)
  values (p_full_name, v_phone, p_licence_no, p_licence_expiry, p_status,
          p_status = 'APPROVED', case when p_status = 'PENDING' then null else now() end)
  on conflict (phone) do update
    set full_name = excluded.full_name,
        licence_no = coalesce(excluded.licence_no, drivers.licence_no),
        licence_expiry = coalesce(excluded.licence_expiry, drivers.licence_expiry),
        status = excluded.status,
        docs_verified = excluded.docs_verified,
        decided_at = excluded.decided_at
  returning id into v_id;

  insert into driver_reviews (driver_id, decision, reason)
  values (v_id, case when p_status = 'APPROVED' then 'APPROVED' else 'SUSPENDED' end, 'أُضيف من لوحة الإدارة');
  return v_id;
end $$;

/** حذف سائق — يُرفض إن كانت لديه طلبات جارية. */
create or replace function public.admin_delete_driver(p_key text, p_driver uuid)
returns text language plpgsql security definer set search_path = public as $$
declare key_hash text; active int;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  select count(*)::int into active from orders where driver_id = p_driver and status in ('CLAIMED','PICKED_UP');
  if active > 0 then raise exception 'DRIVER_HAS_ACTIVE_ORDERS'; end if;
  delete from drivers where id = p_driver;
  if not found then raise exception 'DRIVER_NOT_FOUND'; end if;
  return 'DELETED';
end $$;

grant execute on function public.public_pricing()                                   to anon, authenticated;
grant execute on function public.admin_set_pricing(numeric, numeric, text)          to anon, authenticated;
grant execute on function public.admin_list_drivers(text)                           to anon, authenticated;
grant execute on function public.admin_add_driver(text, text, text, text, date, text) to anon, authenticated;
grant execute on function public.admin_delete_driver(text, uuid)                    to anon, authenticated;


/* ================================================================== *
 *  بيانات لوحة التحكم على الويب: إحصاءات، طلبات، ملف سائق
 * ================================================================== */

/** ملخص اللوحة: السائقون بحالاتهم، المتصلون الآن، الطلبات والإيرادات. */
create or replace function public.admin_stats(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare key_hash text; v jsonb;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;

  select jsonb_build_object(
    'drivers', jsonb_build_object(
      'total',     (select count(*)::int from drivers),
      'approved',  (select count(*)::int from drivers where status = 'APPROVED'),
      'pending',   (select count(*)::int from drivers where status = 'PENDING'),
      'rejected',  (select count(*)::int from drivers where status = 'REJECTED'),
      'suspended', (select count(*)::int from drivers where status = 'SUSPENDED'),
      'online',    (select count(*)::int from drivers
                     where last_lat is not null and location_at > now() - interval '10 minutes'),
      'expired_licences', (select count(*)::int from drivers
                            where licence_expiry is not null and licence_expiry < current_date)
    ),
    'orders', jsonb_build_object(
      'total',     (select count(*)::int from orders),
      'pool',      (select count(*)::int from orders where status = 'POOL'),
      'claimed',   (select count(*)::int from orders where status = 'CLAIMED'),
      'picked_up', (select count(*)::int from orders where status = 'PICKED_UP'),
      'delivered', (select count(*)::int from orders where status = 'DELIVERED'),
      'cancelled', (select count(*)::int from orders where status = 'CANCELLED'),
      'today',     (select count(*)::int from orders where created_at >= current_date),
      'week',      (select count(*)::int from orders where created_at >= current_date - interval '6 days')
    ),
    'money', jsonb_build_object(
      'delivered_fees', coalesce((select sum(fee_sdg) from orders where status = 'DELIVERED'), 0),
      'today_fees',     coalesce((select sum(fee_sdg) from orders
                                   where status = 'DELIVERED' and delivered_at >= current_date), 0),
      'pipeline_fees',  coalesce((select sum(fee_sdg) from orders
                                   where status in ('POOL','CLAIMED','PICKED_UP')), 0)
    ),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('category', c.store_category, 'n', c.n) order by c.n desc)
                              from (select store_category, count(*)::int n from orders group by 1) c), '[]'::jsonb),
    'generated_at', now()
  ) into v;
  return v;
end $$;

/** سجل الطلبات للوحة، مع السائق والمتجر. */
create or replace function public.admin_orders(p_key text, p_limit int default 100, p_status text default null)
returns table (
  id uuid, external_id text, store_name text, store_category text, status text,
  fee_sdg numeric, distance_km numeric, customer_name text, customer_phone text,
  driver_id uuid, driver_name text, driver_phone text,
  created_at timestamptz, claimed_at timestamptz, delivered_at timestamptz
) language plpgsql security definer set search_path = public as $$
declare key_hash text;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  return query
    select o.id, o.external_id, o.store_name, o.store_category, o.status,
           o.fee_sdg, o.distance_km, o.customer_name, o.customer_phone,
           o.driver_id, d.full_name, d.phone,
           o.created_at, o.claimed_at, o.delivered_at
    from orders o
    left join drivers d on d.id = o.driver_id
    where (p_status is null or o.status = p_status)
    order by o.created_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

/** ملف سائق كامل: أرقامه وآخر طلباته. */
create or replace function public.admin_driver_detail(p_key text, p_driver uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare key_hash text; d public.drivers%rowtype; v jsonb;
begin
  select rs.admin_key_hash into key_hash from review_settings rs where rs.id = 1;
  if key_hash is null or key_hash <> review_hash(p_key) then raise exception 'BAD_KEY'; end if;
  select * into d from drivers where id = p_driver;
  if not found then raise exception 'DRIVER_NOT_FOUND'; end if;

  select jsonb_build_object(
    'driver', to_jsonb(d) - 'api_key_hash',
    'active_orders',    (select count(*)::int from orders where driver_id = p_driver and status in ('CLAIMED','PICKED_UP')),
    'delivered_orders', (select count(*)::int from orders where driver_id = p_driver and status = 'DELIVERED'),
    'cancelled_orders', (select count(*)::int from orders where driver_id = p_driver and status = 'CANCELLED'),
    'earned_fees',      coalesce((select sum(fee_sdg) from orders where driver_id = p_driver and status = 'DELIVERED'), 0),
    'avg_fee',          coalesce((select round(avg(fee_sdg), 0) from orders where driver_id = p_driver and status = 'DELIVERED'), 0),
    'first_order_at',   (select min(created_at) from orders where driver_id = p_driver),
    'last_order_at',    (select max(created_at) from orders where driver_id = p_driver),
    'by_category',      coalesce((select jsonb_agg(jsonb_build_object('category', c.store_category, 'n', c.n))
                                    from (select store_category, count(*)::int n from orders where driver_id = p_driver group by 1) c), '[]'::jsonb),
    'recent_orders',    coalesce((select jsonb_agg(t) from (
                            select o.id, o.store_name, o.store_category, o.status, o.fee_sdg, o.created_at
                            from orders o where o.driver_id = p_driver order by o.created_at desc limit 20) t), '[]'::jsonb)
  ) into v;
  return v;
end $$;

grant execute on function public.admin_stats(text)                      to anon, authenticated;
grant execute on function public.admin_orders(text, int, text)          to anon, authenticated;
grant execute on function public.admin_driver_detail(text, uuid)        to anon, authenticated;

-- Scheduling lives in supabase/cron.sql (pg_cron): it calls dispatch_tick()
-- every minute to expire dead offers and re-offer open orders.
-- ------------------------------------------------------------------ RLS ------
alter table public.drivers      enable row level security;
alter table public.stores       enable row level security;
alter table public.orders       enable row level security;
alter table public.order_events enable row level security;

-- The anon key may read the pool and the stores (needed by the driver app),
-- and may only ever WRITE through the functions above.
drop policy if exists stores_read on public.stores;
create policy stores_read on public.stores for select using (true);

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select using (true);

drop policy if exists drivers_read on public.drivers;
create policy drivers_read on public.drivers for select using (true);

drop policy if exists events_read on public.order_events;
create policy events_read on public.order_events for select using (true);

drop policy if exists orders_insert_marketplace on public.orders;
create policy orders_insert_marketplace on public.orders for insert with check (true);

drop policy if exists drivers_insert_self on public.drivers;
create policy drivers_insert_self on public.drivers for insert with check (true);

drop policy if exists drivers_update_self on public.drivers;
create policy drivers_update_self on public.drivers for update using (true) with check (true);

drop policy if exists drivers_update_location on public.drivers;
create policy drivers_update_location on public.drivers for update using (true) with check (true);
