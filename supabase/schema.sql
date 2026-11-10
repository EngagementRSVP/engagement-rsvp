-- Engagement RSVP database. Paste this whole file into Supabase → SQL Editor → Run.
-- Change ONLY the email on the next line to the email you'll use to sign in to the tracker.
create table if not exists public.hosts (email text primary key);
insert into public.hosts (email) values ('YOUR-EMAIL-HERE') on conflict do nothing;

-- Invitation details (a single row)
create table if not exists public.event (
  id int primary key default 1 check (id = 1),
  name1 text not null default '', name2 text not null default '',
  date text not null default '', time text not null default '',
  venue text not null default '', deadline text not null default '',
  host_phone text not null default ''
);
insert into public.event (id, name1, name2, date, time, venue, deadline, host_phone)
values (1, 'Hazar', 'Yousef', 'Sunday, 06 December 2026', '5:30 PM', 'Vida Marina Hotel, Dubai', '1 December', '+971555674429')
on conflict (id) do nothing;

-- One row per invitation
create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  phone text not null default '',
  seats int not null default 2 check (seats between 1 and 50),
  status text not null default 'pending' check (status in ('pending', 'attending', 'declined')),
  coming int not null default 0 check (coming >= 0 and coming <= seats),
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
insert into public.guests (name, phone, seats)
select 'Yousef Issa', '0509413587', 1
where not exists (select 1 from public.guests);

-- Access rules: guests can read the invitation only; the host can do everything.
alter table public.hosts  enable row level security;
alter table public.event  enable row level security;
alter table public.guests enable row level security;

create or replace function public.is_host() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.hosts h where lower(h.email) = lower(auth.jwt() ->> 'email'));
$$;

drop policy if exists "anyone reads event" on public.event;
create policy "anyone reads event" on public.event for select to anon, authenticated using (true);
drop policy if exists "host edits event" on public.event;
create policy "host edits event" on public.event for update to authenticated using (public.is_host()) with check (public.is_host());
drop policy if exists "host manages guests" on public.guests;
create policy "host manages guests" on public.guests for all to authenticated using (public.is_host()) with check (public.is_host());

-- Same phone matching as the original page: digits only, drop 00 prefix and the local leading 0, compare endings.
create or replace function public.norm_phone(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if left(d, 2) = '00' then d := substr(d, 3); end if;
  if length(d) = 10 and left(d, 1) = '0' then d := substr(d, 2); end if;
  return d;
end $$;

create or replace function public.phone_match(a text, b text) returns boolean
language sql immutable set search_path = '' as $$
  select length(public.norm_phone(a)) >= 7 and length(public.norm_phone(b)) >= 7
     and (right(public.norm_phone(a), length(public.norm_phone(b))) = public.norm_phone(b)
       or right(public.norm_phone(b), length(public.norm_phone(a))) = public.norm_phone(a));
$$;

-- Guests find their own invitation by phone; they never see the rest of the list.
create or replace function public.lookup_guest(p_phone text)
returns table (id uuid, name text, seats int, status text, coming int)
language sql stable security definer set search_path = '' as $$
  select g.id, g.name, g.seats, g.status, g.coming from public.guests g
  where public.phone_match(g.phone, p_phone)
  order by g.created_at limit 1;
$$;

-- Guests save their reply; the phone must match the invitation and the count is capped at the seats offered.
create or replace function public.submit_rsvp(p_id uuid, p_phone text, p_attending boolean, p_coming int)
returns text
language plpgsql security definer set search_path = '' as $$
declare g public.guests;
begin
  select * into g from public.guests where id = p_id;
  if g.id is null or not public.phone_match(g.phone, p_phone) then raise exception 'invitation not found'; end if;
  update public.guests set
    status = case when p_attending then 'attending' else 'declined' end,
    coming = case when p_attending then least(greatest(coalesce(p_coming, 1), 1), g.seats) else 0 end,
    responded_at = now()
  where id = p_id;
  return 'ok';
end $$;

revoke all on function public.lookup_guest(text), public.submit_rsvp(uuid, text, boolean, int), public.is_host() from public;
grant execute on function public.lookup_guest(text), public.submit_rsvp(uuid, text, boolean, int) to anon, authenticated;
grant execute on function public.is_host() to authenticated;

-- Live updates for the tracker
do $$ begin
  alter publication supabase_realtime add table public.guests, public.event;
exception when duplicate_object then null; end $$;
