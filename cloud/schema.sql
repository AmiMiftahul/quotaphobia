-- Run this once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Also enable Authentication > Sign In / Providers > "Allow anonymous sign-ins".

create table public.runs (
  id bigint generated always as identity primary key,
  player_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 16),
  rounds_cleared integer not null check (rounds_cleared between 0 and 1000),
  total_scrap integer not null check (total_scrap between 0 and 10000000),
  crew_size integer not null check (crew_size between 1 and 4),
  created_at timestamptz not null default now()
);

create index runs_leaderboard_idx on public.runs (total_scrap desc);

-- Row Level Security: nothing is allowed unless a policy below allows it.
alter table public.runs enable row level security;

create policy "Anyone can read the leaderboard"
  on public.runs for select
  to anon, authenticated
  using (true);

create policy "Players can add only their own runs"
  on public.runs for insert
  to authenticated
  with check (auth.uid() = player_id);

-- Column permissions: players can't choose player_id or created_at, and player
-- ids aren't readable. There are no update or delete permissions at all.
revoke all on public.runs from anon, authenticated;
grant select (display_name, rounds_cleared, total_scrap, crew_size, created_at) on public.runs to anon, authenticated;
grant insert (display_name, rounds_cleared, total_scrap, crew_size) on public.runs to authenticated;
