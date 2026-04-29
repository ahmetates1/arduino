-- Tek GATEWAY satiri: firmware PATCH ile `value` guncellenir; `updated_at` son canlilik zamani.
do $migration$
begin
  if not exists (
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = 'sensor_data'
  ) then
    return;
  end if;

  -- Eski coklu GATEWAY INSERT'leri: en yeni created_at tek satir kalsin
  with ranked as (
    select ctid,
      row_number() over (order by created_at desc nulls last) as rn
    from public.sensor_data
    where name = 'GATEWAY'
  )
  delete from public.sensor_data d
  using ranked r
  where d.ctid = r.ctid
    and r.rn > 1;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'sensor_data'
      and column_name = 'updated_at'
  ) then
    alter table public.sensor_data
      add column updated_at timestamptz not null default now();
  end if;

  update public.sensor_data
  set updated_at = coalesce(created_at, now())
  where updated_at is null;

  comment on column public.sensor_data.updated_at is
    'PATCH ile guncellemede otomatik yenilenir (gateway heartbeat).';

  -- Ayni anda en fazla bir GATEWAY satiri
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'sensor_data_one_gateway_name'
  ) then
    create unique index sensor_data_one_gateway_name
      on public.sensor_data (name)
      where (name = 'GATEWAY');
  end if;

  -- Baslangic satiri (firmware PATCH icin hedef)
  insert into public.sensor_data (name, value)
  select 'GATEWAY', 1
  where not exists (select 1 from public.sensor_data where name = 'GATEWAY');

  -- Her UPDATE'te updated_at = now()
  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'touch_sensor_data_updated_at'
  ) then
    create function public.touch_sensor_data_updated_at()
    returns trigger
    language plpgsql
    as $fn$
    begin
      new.updated_at := now();
      return new;
    end;
    $fn$;
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgname = 'trg_sensor_data_touch_updated_at'
  ) then
    create trigger trg_sensor_data_touch_updated_at
      before update on public.sensor_data
      for each row
      execute procedure public.touch_sensor_data_updated_at();
  end if;
end
$migration$;
