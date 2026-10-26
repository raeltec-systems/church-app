-- The staff catalog checks and share-locks the editor's active Content grant. Keep its
-- API wrapper VOLATILE so PostgREST does not run that authorization check in a read-only tx.
create or replace function api.content_staff_bibles()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_bibles();
$$;

notify pgrst, 'reload schema';
