-- Mevcut sensor_data_test tablosuna raw_unparsed ekler (tablo zaten varsa bunu calistirin)

alter table public.sensor_data_test add column if not exists raw_unparsed text;
alter table public.sensor_data_test add column if not exists is_valid boolean not null default false;

alter table public.sensor_data_test alter column network_id drop not null;
alter table public.sensor_data_test alter column node_id drop not null;
alter table public.sensor_data_test alter column seq drop not null;
alter table public.sensor_data_test alter column uptime_sec drop not null;
alter table public.sensor_data_test alter column high drop not null;

comment on column public.sensor_data_test.raw_unparsed is
  'Beklenen format disi gelen satir (oldugu gibi); gecerli pakette NULL.';
