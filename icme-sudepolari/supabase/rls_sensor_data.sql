-- Kalici tanim: `supabase/migrations/20260429140000_sensor_data_enable_rls.sql`
-- Supabase SQL Editor veya `supabase db push` ile uygulanir.
--
-- Eski manuel taslaklar (artik migration dosyasinda):

-- alter table public.sensor_data enable row level security;
-- create policy "sensor_insert_anon" ...
-- create policy "sensor_select_authenticated" ...
