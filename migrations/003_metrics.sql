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
