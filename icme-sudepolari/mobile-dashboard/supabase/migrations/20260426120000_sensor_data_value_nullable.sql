-- Gateway: 5 dk boyunca LoRa paketi gelmezse `value: null` INSERT icin
-- `sensor_data.value` NULL kabul etmeli.
--
-- Calistirma:
--   - Supabase Dashboard > SQL Editor: bu dosyanin icerigini yapistirip Run
--   - veya: `supabase link` sonrasi `supabase db push` (projede config.toml varsa)
--
-- Tablo/kolon yoksa hata vermez (kosullu blok).

do $migration$
begin
  if exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'sensor_data'
      and c.column_name = 'value'
  ) then
    alter table public.sensor_data
      alter column value drop not null;

    comment on column public.sensor_data.value is
      'Doluluk yuzdesi veya veri yok (gateway stale heartbeat: JSON null).';
  end if;
end
$migration$;
