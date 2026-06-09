-- ESP32 LoRa test gateway: sensor_data_test
-- Supabase Dashboard > SQL Editor > yapistir > Run
--
-- Zaten tablo varsa: dosyanin sonundaki ALTER bolumunu calistirin.

create table if not exists public.sensor_data_test (
  id bigint generated always as identity primary key,
  raw text not null,
  -- Beklenen format disi / parse edilemeyen satir (oldugu gibi); gecerli pakette NULL
  raw_unparsed text,
  is_valid boolean not null default false,
  network_id integer,
  node_id integer,
  seq integer,
  uptime_sec integer,
  high integer,
  created_at timestamptz not null default now()
);

create index if not exists sensor_data_test_created_at_idx
  on public.sensor_data_test (created_at desc);

alter table public.sensor_data_test enable row level security;

drop policy if exists "sensor_data_test_anon_select" on public.sensor_data_test;
drop policy if exists "sensor_data_test_anon_insert" on public.sensor_data_test;

create policy "sensor_data_test_anon_select"
  on public.sensor_data_test
  for select
  to anon
  using (true);

create policy "sensor_data_test_anon_insert"
  on public.sensor_data_test
  for insert
  to anon
  with check (true);

comment on table public.sensor_data_test is
  'ESP32 E220 test: raw=her zaman gelen satir; raw_unparsed=sadece gecersiz formatta.';
comment on column public.sensor_data_test.raw_unparsed is
  'network|node|seq|sn|high parse edilemezse veya network uyusmazsa ham metin.';

-- ---------------------------------------------------------------------------
-- Tablo daha once eski semayla olusturulduysa (zorunlu kolonlar vardi):
-- ---------------------------------------------------------------------------
-- alter table public.sensor_data_test add column if not exists raw_unparsed text;
-- alter table public.sensor_data_test add column if not exists is_valid boolean not null default false;
-- alter table public.sensor_data_test alter column network_id drop not null;
-- alter table public.sensor_data_test alter column node_id drop not null;
-- alter table public.sensor_data_test alter column seq drop not null;
-- alter table public.sensor_data_test alter column uptime_sec drop not null;
-- alter table public.sensor_data_test alter column high drop not null;
