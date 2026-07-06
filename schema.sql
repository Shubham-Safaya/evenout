-- Hisaab — shared expense tracking (Splitwise-style), Supabase schema.
-- Run this once in the Supabase SQL editor (paste the whole file).
--
-- Security model: capability URLs. Every read/write goes through a
-- SECURITY DEFINER function that requires the group's UUID. Direct table
-- access for anon/authenticated is revoked, so the public anon key cannot
-- list or enumerate anything. Knowing a group's UUID *is* the membership.

create extension if not exists pgcrypto;

-- ── Tables ────────────────────────────────────────────────────────────
create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  currency text not null default 'USD' check (char_length(currency) = 3),
  created_at timestamptz not null default now()
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  description text not null check (char_length(description) between 1 and 200),
  amount numeric(12,2) not null check (amount > 0),
  paid_by uuid not null references members(id) on delete cascade,
  is_settlement boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists expense_splits (
  expense_id uuid not null references expenses(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  share numeric(12,2) not null check (share >= 0),
  primary key (expense_id, member_id)
);

create index if not exists idx_members_group on members(group_id);
create index if not exists idx_expenses_group on expenses(group_id, created_at desc);

-- ── Lock down direct access ───────────────────────────────────────────
alter table groups enable row level security;
alter table members enable row level security;
alter table expenses enable row level security;
alter table expense_splits enable row level security;
-- No policies = no direct access. RPCs below run as the table owner.
revoke all on groups, members, expenses, expense_splits from anon, authenticated;

-- ── RPCs (the entire API) ─────────────────────────────────────────────
create or replace function create_group(p_name text, p_currency text, p_members text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid; m text;
begin
  if array_length(p_members, 1) is null or array_length(p_members, 1) < 1 then
    raise exception 'at least one member required';
  end if;
  insert into groups (name, currency) values (p_name, upper(p_currency)) returning id into gid;
  foreach m in array p_members loop
    insert into members (group_id, name) values (gid, m);
  end loop;
  return gid;
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
                  'created_at', e.created_at,
                  'splits', (select json_agg(json_build_object('member_id', s.member_id, 'share', s.share))
                             from expense_splits s where s.expense_id = e.id)
                ) order by e.created_at desc)
                from expenses e where e.group_id = p_group), '[]'::json)
  );
$$;

create or replace function add_member(p_group uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if not exists (select 1 from groups where id = p_group) then
    raise exception 'group not found';
  end if;
  insert into members (group_id, name) values (p_group, p_name) returning id into mid;
  return mid;
end $$;

-- p_splits: [{"member_id": "...", "share": 12.34}, ...]; shares must sum to amount.
create or replace function add_expense(
  p_group uuid, p_description text, p_amount numeric,
  p_paid_by uuid, p_splits json, p_is_settlement boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; total numeric;
begin
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'payer is not a member of this group';
  end if;
  select coalesce(sum((s->>'share')::numeric), 0) into total from json_array_elements(p_splits) s;
  if abs(total - p_amount) > 0.02 then
    raise exception 'splits (%) must sum to amount (%)', total, p_amount;
  end if;
  insert into expenses (group_id, description, amount, paid_by, is_settlement)
  values (p_group, p_description, round(p_amount, 2), p_paid_by, p_is_settlement)
  returning id into eid;
  insert into expense_splits (expense_id, member_id, share)
  select eid, (s->>'member_id')::uuid, round((s->>'share')::numeric, 2)
  from json_array_elements(p_splits) s
  where (s->>'share')::numeric > 0;
  -- every split member must belong to the group
  if exists (select 1 from expense_splits sp join members m on m.id = sp.member_id
             where sp.expense_id = eid and m.group_id <> p_group) then
    raise exception 'split member not in group';
  end if;
  return eid;
end $$;

create or replace function delete_expense(p_group uuid, p_expense uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from expenses where id = p_expense and group_id = p_group;
  if not found then raise exception 'expense not found in this group'; end if;
end $$;

grant execute on function
  create_group(text, text, text[]),
  get_group_data(uuid),
  add_member(uuid, text),
  add_expense(uuid, text, numeric, uuid, json, boolean),
  delete_expense(uuid, uuid)
to anon, authenticated;
