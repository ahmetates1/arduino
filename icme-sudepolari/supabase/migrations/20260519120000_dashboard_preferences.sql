-- Mobil panel: depo karti surukle-birak sirasi (yeniden kurulumda Supabase'ten geri yuklenir).

create table if not exists public.dashboard_preferences (
  id text primary key,
  tank_order text[] not null,
  updated_at timestamptz not null default now()
);

insert into public.dashboard_preferences (id, tank_order)
values (
  'default',
  array['YICME', 'GEBAN', 'TTOKI', 'YTOKI', 'AICME']::text[]
)
on conflict (id) do nothing;

alter table public.dashboard_preferences enable row level security;

drop policy if exists "dashboard_preferences_anon_select" on public.dashboard_preferences;
drop policy if exists "dashboard_preferences_anon_update" on public.dashboard_preferences;

create policy "dashboard_preferences_anon_select"
  on public.dashboard_preferences
  for select
  to anon
  using (true);

create policy "dashboard_preferences_anon_update"
  on public.dashboard_preferences
  for update
  to anon
  using (true)
  with check (true);

comment on table public.dashboard_preferences is
  'Mobil dashboard depo siralamasi; id=default tek satir.';
