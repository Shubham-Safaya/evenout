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
