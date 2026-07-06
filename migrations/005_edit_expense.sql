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
