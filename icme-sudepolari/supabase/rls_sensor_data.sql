-- Supabase SQL Editor'da çalıştırın; tablo/kolon adlarınız farklıysa uyarlayın.
-- Amaç: ESP32 anon key ile INSERT kalabilir; dashboard ise sadece giriş yapmış kullanıcı SELECT yapar.

-- alter table public.sensor_data enable row level security;

-- Gateway (anon) ile yazma — sadece INSERT, kimlik doğrulamasız cihazlar için:
-- create policy "sensor_insert_anon"
--   on public.sensor_data for insert
--   to anon
--   with check (true);

-- Okuma: yalnızca authenticated
-- create policy "sensor_select_authenticated"
--   on public.sensor_data for select
--   to authenticated
--   using (true);
