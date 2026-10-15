-- Story 4.14 (refactor sweep, S1): the comments of the Duties and Follow-ups command entry points
-- name every command their router sends, so a story that adds a command also updates the comment
-- (a later story left both stale before 20261015130404_duties_comment_refresh.sql).
begin;
select plan(4);

-- The router is the app body; the client-facing api wrapper carries the comment.
create temp view routed as
  select p.proname::text as fn, m[1] as command,
         obj_description(('api.' || p.proname || '(jsonb)')::regprocedure, 'pg_proc') as comment
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join lateral regexp_matches(p.prosrc, 'when ''(?:duties|followups)[.]([a-z_]+)''', 'g') as m
   where n.nspname = 'app' and p.proname in ('duties_command', 'followups_command')
     and p.proargtypes = '3802'::oidvector;

select cmp_ok((select count(*) from routed where fn = 'duties_command'), '>=', 22::bigint,
  'the Duties router is read (every 4.1-4.12 command)');
select is_empty(
  $$select command from routed where fn = 'duties_command' and position(command in comment) = 0$$,
  'api.duties_command''s comment names every routed command');
select cmp_ok((select count(*) from routed where fn = 'followups_command'), '>=', 4::bigint,
  'the Follow-ups router is read (every 4.6-4.12 command)');
select is_empty(
  $$select command from routed where fn = 'followups_command' and position(command in comment) = 0$$,
  'api.followups_command''s comment names every routed command');

select * from finish();
rollback;
