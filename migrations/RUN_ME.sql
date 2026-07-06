-- EvenOut — ONE-PASTE migration: runs 002 + 003 + 004 in order.
-- Safe to run even if you already ran some of them (all idempotent).

-- Hisaab v3.0 migration. Run in Supabase SQL Editor (paste whole file, Run).
-- Adds: backdatable expense dates + optional user accounts ("my groups").

-- ── 1. Expense date (backdating; defaults to today) ──────────────────
alter table expenses add column if not exists spent_on date not null default current_date;

-- Postgres would keep the old 6-arg signature as an overload, which makes
-- PostgREST's named-argument dispatch ambiguous — drop it explicitly.
drop function if exists add_expense(uuid, text, numeric, uuid, json, boolean);

create or replace function add_expense(
  p_group uuid, p_description text, p_amount numeric,
  p_paid_by uuid, p_splits json, p_is_settlement boolean default false,
  p_spent_on date default current_date
) returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; total numeric;
begin
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'payer is not a member of this group';
  end if;
  if p_spent_on > current_date then
    raise exception 'expense date cannot be in the future';
  end if;
  select coalesce(sum((s->>'share')::numeric), 0) into total from json_array_elements(p_splits) s;
  if abs(total - p_amount) > 0.02 then
    raise exception 'splits (%) must sum to amount (%)', total, p_amount;
  end if;
  insert into expenses (group_id, description, amount, paid_by, is_settlement, spent_on)
  values (p_group, p_description, round(p_amount, 2), p_paid_by, p_is_settlement, p_spent_on)
  returning id into eid;
  insert into expense_splits (expense_id, member_id, share)
  select eid, (s->>'member_id')::uuid, round((s->>'share')::numeric, 2)
  from json_array_elements(p_splits) s
  where (s->>'share')::numeric > 0;
  if exists (select 1 from expense_splits sp join members m on m.id = sp.member_id
             where sp.expense_id = eid and m.group_id <> p_group) then
    raise exception 'split member not in group';
  end if;
  return eid;
end $$;

create or replace function get_group_data(p_group uuid)
returns json language sql security definer set search_path = public stable as $$
  select json_build_object(
    'group', (select json_build_object('id', g.id, 'name', g.name, 'currency', g.currency) from groups g where g.id = p_group),
    'members', coalesce((select json_agg(json_build_object('id', m.id, 'name', m.name) order by m.created_at)
                from members m where m.group_id = p_group), '[]'::json),
    'expenses', coalesce((select json_agg(json_build_object(
                  'id', e.id, 'description', e.description, 'amount', e.amount,
                  'paid_by', e.paid_by, 'is_settlement', e.is_settlement,
                  'created_at', e.created_at, 'spent_on', e.spent_on,
                  'splits', (select json_agg(json_build_object('member_id', s.member_id, 'share', s.share))
                             from expense_splits s where s.expense_id = e.id)
                ) order by e.spent_on desc, e.created_at desc)
                from expenses e where e.group_id = p_group), '[]'::json)
  );
$$;

grant execute on function
  add_expense(uuid, text, numeric, uuid, json, boolean, date),
  get_group_data(uuid)
to anon, authenticated;

-- ── 2. Optional accounts: remember my groups across devices ──────────
-- Signed-in users (email magic link) can pin groups to their account.
-- Real RLS here: each user sees only their own rows. Nothing else in the
-- schema is affected — link-only usage keeps working exactly as before.
create table if not exists user_groups (
  user_id uuid not null references auth.users(id) on delete cascade,
  group_id uuid not null,
  group_name text not null default '',
  added_at timestamptz not null default now(),
  primary key (user_id, group_id)
);

alter table user_groups enable row level security;

drop policy if exists "own rows select" on user_groups;
drop policy if exists "own rows insert" on user_groups;
drop policy if exists "own rows update" on user_groups;
drop policy if exists "own rows delete" on user_groups;
create policy "own rows select" on user_groups for select to authenticated using (auth.uid() = user_id);
create policy "own rows insert" on user_groups for insert to authenticated with check (auth.uid() = user_id);
create policy "own rows update" on user_groups for update to authenticated using (auth.uid() = user_id);
create policy "own rows delete" on user_groups for delete to authenticated using (auth.uid() = user_id);

grant select, insert, update, delete on user_groups to authenticated;
-- EvenOut v3.1 — privacy-first usage metrics.
-- Run in Supabase SQL Editor after 002_v3.sql.
--
-- What is stored: (day, random-device-token, kind). No names, no emails,
-- no IPs, no group contents, no third parties. The token is a random UUID
-- the browser makes up; it identifies a device only to itself.

create table if not exists usage_pings (
  day date not null default current_date,
  device text not null check (char_length(device) between 8 and 64),
  kind text not null default 'open' check (kind in ('open', 'install')),
  primary key (day, device, kind)
);

alter table usage_pings enable row level security;
revoke all on usage_pings from anon, authenticated;

create or replace function log_ping(p_device text, p_kind text default 'open')
returns void language sql security definer set search_path = public as $$
  insert into usage_pings (device, kind) values (p_device, coalesce(p_kind, 'open'))
  on conflict do nothing;
$$;

-- Aggregates only — individual tokens never leave the database.
create or replace function get_public_stats()
returns json language sql security definer set search_path = public stable as $$
  select json_build_object(
    'total_groups', (select count(*) from groups),
    'total_expenses', (select count(*) from expenses where not is_settlement),
    'total_settlements', (select count(*) from expenses where is_settlement),
    'dau', (select count(distinct device) from usage_pings where day = current_date and kind = 'open'),
    'mau', (select count(distinct device) from usage_pings where day > current_date - 30 and kind = 'open'),
    'installs', (select count(distinct device) from usage_pings where kind = 'install'),
    'daily', coalesce((
      select json_agg(json_build_object('day', d.day, 'actives', coalesce(u.actives, 0)) order by d.day)
      from generate_series(current_date - 29, current_date, interval '1 day') as d(day)
      left join (select day, count(distinct device) as actives
                 from usage_pings where kind = 'open' group by day) u on u.day = d.day
    ), '[]'::json)
  );
$$;

grant execute on function log_ping(text, text), get_public_stats() to anon, authenticated;
-- EvenOut — make stats owner-only.
-- Stats are gated to admin emails; the public stats RPC is removed.

create table if not exists admins (email text primary key);
insert into admins (email) values ('safayashubham@gmail.com') on conflict do nothing;
alter table admins enable row level security;
revoke all on admins from anon, authenticated;

drop function if exists get_public_stats();

create or replace function get_stats()
returns json language plpgsql security definer set search_path = public stable as $$
declare result json;
begin
  if coalesce(auth.jwt() ->> 'email', '') not in (select email from admins) then
    raise exception 'not authorized';
  end if;
  select json_build_object(
    'total_groups', (select count(*) from groups),
    'total_expenses', (select count(*) from expenses where not is_settlement),
    'total_settlements', (select count(*) from expenses where is_settlement),
    'dau', (select count(distinct device) from usage_pings where day = current_date and kind = 'open'),
    'mau', (select count(distinct device) from usage_pings where day > current_date - 30 and kind = 'open'),
    'installs', (select count(distinct device) from usage_pings where kind = 'install'),
    'daily', coalesce((
      select json_agg(json_build_object('day', d.day, 'actives', coalesce(u.actives, 0)) order by d.day)
      from generate_series(current_date - 29, current_date, interval '1 day') as d(day)
      left join (select day, count(distinct device) as actives
                 from usage_pings where kind = 'open' group by day) u on u.day = d.day
    ), '[]'::json)
  ) into result;
  return result;
end $$;

revoke execute on function get_stats() from anon;
grant execute on function get_stats() to authenticated;

-- EvenOut — edit an existing expense (description, amount, payer, date,
-- and the people/shares in the split). Same validation as add_expense.

create or replace function update_expense(
  p_group uuid, p_expense uuid, p_description text, p_amount numeric,
  p_paid_by uuid, p_splits json, p_spent_on date
) returns void language plpgsql security definer set search_path = public as $$
declare total numeric;
begin
  if not exists (select 1 from expenses where id = p_expense and group_id = p_group) then
    raise exception 'expense not found in this group';
  end if;
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'payer is not a member of this group';
  end if;
  if p_spent_on > current_date then
    raise exception 'expense date cannot be in the future';
  end if;
  if p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  select coalesce(sum((s->>'share')::numeric), 0) into total from json_array_elements(p_splits) s;
  if abs(total - p_amount) > 0.02 then
    raise exception 'splits (%) must sum to amount (%)', total, p_amount;
  end if;

  update expenses
     set description = p_description, amount = round(p_amount, 2),
         paid_by = p_paid_by, spent_on = p_spent_on
   where id = p_expense and group_id = p_group;

  delete from expense_splits where expense_id = p_expense;
  insert into expense_splits (expense_id, member_id, share)
  select p_expense, (s->>'member_id')::uuid, round((s->>'share')::numeric, 2)
  from json_array_elements(p_splits) s
  where (s->>'share')::numeric > 0;

  if exists (select 1 from expense_splits sp join members m on m.id = sp.member_id
             where sp.expense_id = p_expense and m.group_id <> p_group) then
    raise exception 'split member not in group';
  end if;
end $$;

grant execute on function
  update_expense(uuid, uuid, text, numeric, uuid, json, date)
to anon, authenticated;

-- EvenOut v3.3 — expense categories.
-- Adds a category to every expense (default 'general'); old rows get it too.

alter table expenses add column if not exists category text not null default 'general';

-- Replace both write RPCs with category-aware signatures.
-- (Explicit drops: Postgres keeps old arg-count versions as overloads,
--  which breaks PostgREST named-argument dispatch.)
drop function if exists add_expense(uuid, text, numeric, uuid, json, boolean, date);
drop function if exists update_expense(uuid, uuid, text, numeric, uuid, json, date);

create or replace function add_expense(
  p_group uuid, p_description text, p_amount numeric,
  p_paid_by uuid, p_splits json, p_is_settlement boolean default false,
  p_spent_on date default current_date, p_category text default 'general'
) returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; total numeric;
begin
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'payer is not a member of this group';
  end if;
  if p_spent_on > current_date then
    raise exception 'expense date cannot be in the future';
  end if;
  select coalesce(sum((s->>'share')::numeric), 0) into total from json_array_elements(p_splits) s;
  if abs(total - p_amount) > 0.02 then
    raise exception 'splits (%) must sum to amount (%)', total, p_amount;
  end if;
  insert into expenses (group_id, description, amount, paid_by, is_settlement, spent_on, category)
  values (p_group, p_description, round(p_amount, 2), p_paid_by, p_is_settlement, p_spent_on,
          coalesce(nullif(trim(p_category), ''), 'general'))
  returning id into eid;
  insert into expense_splits (expense_id, member_id, share)
  select eid, (s->>'member_id')::uuid, round((s->>'share')::numeric, 2)
  from json_array_elements(p_splits) s
  where (s->>'share')::numeric > 0;
  if exists (select 1 from expense_splits sp join members m on m.id = sp.member_id
             where sp.expense_id = eid and m.group_id <> p_group) then
    raise exception 'split member not in group';
  end if;
  return eid;
end $$;

create or replace function update_expense(
  p_group uuid, p_expense uuid, p_description text, p_amount numeric,
  p_paid_by uuid, p_splits json, p_spent_on date, p_category text default 'general'
) returns void language plpgsql security definer set search_path = public as $$
declare total numeric;
begin
  if not exists (select 1 from expenses where id = p_expense and group_id = p_group) then
    raise exception 'expense not found in this group';
  end if;
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'payer is not a member of this group';
  end if;
  if p_spent_on > current_date then
    raise exception 'expense date cannot be in the future';
  end if;
  if p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  select coalesce(sum((s->>'share')::numeric), 0) into total from json_array_elements(p_splits) s;
  if abs(total - p_amount) > 0.02 then
    raise exception 'splits (%) must sum to amount (%)', total, p_amount;
  end if;

  update expenses
     set description = p_description, amount = round(p_amount, 2),
         paid_by = p_paid_by, spent_on = p_spent_on,
         category = coalesce(nullif(trim(p_category), ''), 'general')
   where id = p_expense and group_id = p_group;

  delete from expense_splits where expense_id = p_expense;
  insert into expense_splits (expense_id, member_id, share)
  select p_expense, (s->>'member_id')::uuid, round((s->>'share')::numeric, 2)
  from json_array_elements(p_splits) s
  where (s->>'share')::numeric > 0;

  if exists (select 1 from expense_splits sp join members m on m.id = sp.member_id
             where sp.expense_id = p_expense and m.group_id <> p_group) then
    raise exception 'split member not in group';
  end if;
end $$;

-- get_group_data returns the category
create or replace function get_group_data(p_group uuid)
returns json language sql security definer set search_path = public stable as $$
  select json_build_object(
    'group', (select json_build_object('id', g.id, 'name', g.name, 'currency', g.currency) from groups g where g.id = p_group),
    'members', coalesce((select json_agg(json_build_object('id', m.id, 'name', m.name) order by m.created_at)
                from members m where m.group_id = p_group), '[]'::json),
    'expenses', coalesce((select json_agg(json_build_object(
                  'id', e.id, 'description', e.description, 'amount', e.amount,
                  'paid_by', e.paid_by, 'is_settlement', e.is_settlement,
                  'created_at', e.created_at, 'spent_on', e.spent_on,
                  'category', e.category,
                  'splits', (select json_agg(json_build_object('member_id', s.member_id, 'share', s.share))
                             from expense_splits s where s.expense_id = e.id)
                ) order by e.spent_on desc, e.created_at desc)
                from expenses e where e.group_id = p_group), '[]'::json)
  );
$$;

grant execute on function
  add_expense(uuid, text, numeric, uuid, json, boolean, date, text),
  update_expense(uuid, uuid, text, numeric, uuid, json, date, text),
  get_group_data(uuid)
to anon, authenticated;
