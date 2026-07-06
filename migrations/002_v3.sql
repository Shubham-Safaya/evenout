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
