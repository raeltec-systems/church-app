-- Synthetic tracer data only. Never put real church or member data in seeds.
insert into app.platform_status (id, status, message, is_synthetic, updated_at)
values (
  1,
  'operational',
  'SYNTHETIC tracer status: the platform path is reachable. Not real church data.',
  true,
  now()
)
on conflict (id) do update
  set status = excluded.status,
      message = excluded.message,
      is_synthetic = excluded.is_synthetic,
      updated_at = excluded.updated_at;
