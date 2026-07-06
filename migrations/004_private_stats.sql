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
