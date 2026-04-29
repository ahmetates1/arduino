-- Supabase "Table publicly accessible / rls_disabled_in_public" uyarisini giderir.
-- RLS acildiktan sonra **policy olmayan** tum roller icin satir gorunmez / yazilamaz.
--
-- Bu projede Flutter + ESP32 `anon` (publishable) anahtar kullaniyor:
--   SELECT  : mobil panel
--   INSERT  : gateway depo verisi + null stale satirlari
--   UPDATE  : sadece name = 'GATEWAY' (heartbeat PATCH)
--
-- Not: `anon` anahtari uygulama icinde oldugu surece policy ne izin veriyorsa o yapilir;
-- tam kilitleme icin ileride Supabase Auth + SELECT sadece authenticated gibi sikilastirma dusunulebilir.

alter table public.sensor_data enable row level security;

drop policy if exists "sensor_data_anon_select" on public.sensor_data;
drop policy if exists "sensor_data_anon_insert" on public.sensor_data;
drop policy if exists "sensor_data_anon_update_gateway" on public.sensor_data;
drop policy if exists "sensor_data_authenticated_select" on public.sensor_data;

create policy "sensor_data_anon_select"
  on public.sensor_data
  for select
  to anon
  using (true);

create policy "sensor_data_anon_insert"
  on public.sensor_data
  for insert
  to anon
  with check (true);

-- Gateway firmware: PATCH ?name=eq.GATEWAY — baska satirlari anon ile degistiremez
create policy "sensor_data_anon_update_gateway"
  on public.sensor_data
  for update
  to anon
  using (name = 'GATEWAY')
  with check (name = 'GATEWAY');

-- Ileride Supabase Auth kullanilirsa oturum acmis kullanicilar da okuyabilsin
create policy "sensor_data_authenticated_select"
  on public.sensor_data
  for select
  to authenticated
  using (true);

comment on table public.sensor_data is
  'RLS acik; anon: select+insert, update yalnizca GATEWAY satiri.';
