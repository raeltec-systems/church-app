-- Story 6.8: hymn favourites and Hymns for this Sunday. The edition record and item-number checks,
-- the registries (member commands, kind scopes, replay scopes) and the three replaced authority
-- functions, member-only favourites (two sessions, another member, Pending, held, anon, replay),
-- the Sunday list for Admin, Media and a worship leader granted through the 2.3 command (Pastor,
-- plain member and Pending refused, stale revisions, revocation, no leak to other kinds), the public
-- and staff reads, immutability, and the two erase parts with the fail-closed purge. Every account,
-- phone and name is SYNTHETIC (fictional range +1 202 555 0181-0189). Church time is Africa/Lusaka.
begin;
select plan(145);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000168' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000168' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (80 + n)::text $$;
-- Claims of account n in session k (k = 1 is its first session, 2 its second phone).
create function pg_temp.c(n int, k int default 1) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1',
    'session_id', case when k = 1 then pg_temp.s(n) else pg_temp.s(n + 50) end,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.envelope(n int, p_fn text, p_command text, p_expected bigint, p_payload jsonb,
                                 p_request uuid, k int default 1)
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n, k)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_fn) into r
    using jsonb_build_object('version', 1, 'command', p_command, 'request_id', p_request,
                             'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid(), k int default 1)
returns jsonb language sql as $$
  select pg_temp.envelope(n, 'content_command', p_command, p_expected, p_payload, p_request, k)
$$;
create function pg_temp.grant_cmd(n int, p_command text, p_member uuid, p_scope uuid)
returns jsonb language sql as $$
  select pg_temp.envelope(n, 'identity_grant_command', p_command,
                          (select revision from app.identity_grant_sets where member_id = p_member),
                          jsonb_build_object('member_id', p_member, 'scope_kind', 'worship_leader',
                                             'scope_id', p_scope), gen_random_uuid())
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- A read as account n (or anon when n is null): its JSON, or 'SQLSTATE|message|detail'.
create function pg_temp.read(n int, p_sql text, k int default 1) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  if n is null then
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', pg_temp.c(n, k)::text, true);
    set local role authenticated;
  end if;
  begin
    execute p_sql into r;
    reset role;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return to_jsonb(v_state || '|' || v_msg || '|' || coalesce(v_detail, ''));
  end;
end;
$$;
create function pg_temp.fav(p_item text, p_edition text default 'bicc-tonga-2012') returns jsonb language sql as
$$ select jsonb_build_object('edition', p_edition, 'item', p_item) $$;
create function pg_temp.items(n int, k int default 1) returns text language sql as $$
  select string_agg(f ->> 'item', ',' order by f ->> 'item')
    from jsonb_array_elements(pg_temp.read(n, 'select api.content_my_hymn_favourites()', k) -> 'favourites') f
$$;
-- The church-time Sunday k weeks from this Sunday, as YYYY-MM-DD.
create function pg_temp.sun(k int) returns text language sql as
$$ select to_char(app.content_this_sunday() + 7 * k, 'YYYY-MM-DD') $$;
create function pg_temp.list_rev() returns bigint language sql as
$$ select revision from app.content_sunday_hymn_lists $$;
create function pg_temp.sunday(p_sunday text, p_items jsonb, p_edition text default 'bicc-tonga-2012')
returns jsonb language sql as
$$ select jsonb_build_object('sunday', p_sunday, 'edition', p_edition, 'items', p_items) $$;
create function pg_temp.list_id() returns uuid language sql as
$$ select list_id from app.content_sunday_hymn_lists $$;

-- Accounts: 1 Admin; 2 Media M; 3 worship leader W (granted below); 4 member A (two phones);
-- 5 member B; 6 Pending (no member link); 7 Pastor P; 8 member E (erased at the end, also a
-- worship leader); 9 member H (put on hold).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n;
select pg_temp.session(pg_temp.u(4), pg_temp.s(54));
select app.platform_set_environment('local', 'pgtap content hymn lists');
-- The list record's revision as a fresh database has it (an earlier E2E run moves it on; rolled back).
update app.content_sunday_hymn_lists set revision = 1;
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Hymn Member ' || n,
                                                         'pgtap content hymn lists')
  from generate_series(1, 9) n where n <> 6;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'media', 'israel'), (pg_temp.mid(7), 'pastor', 'israel');

-- Structure, registries and privileges ----------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['content_hymn_editions', 'content_member_commands', 'content_kind_scopes',
                    'content_replay_scopes', 'content_hymn_favourites', 'content_sunday_hymn_lists',
                    'content_sunday_hymn_revisions', 'content_sunday_hymn_items']) t;
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relkind = 'r'
              and c.relname in ('content_hymn_editions', 'content_member_commands', 'content_kind_scopes',
                                'content_replay_scopes', 'content_hymn_favourites',
                                'content_sunday_hymn_lists', 'content_sunday_hymn_revisions',
                                'content_sunday_hymn_items')),
  'RLS is enabled on every table of this story');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relkind in ('r', 'S') and c.relname like 'content\_%'
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'))),
  0, 'no client role has any privilege on a Content table or sequence');
create temp table own_functions as
  select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'api')
     and (p.proname ~ '^content_(hymn|sunday|my_hymn|public_sunday|staff_sunday|this_sunday|scope_target|member_|register_(member|kind|replay))'
          or p.proname in ('content_editor_capacity', 'content_authorize_command', 'content_in_scope'));
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname in (select proname from own_functions)
       and has_function_privilege('anon', p.oid, 'EXECUTE') order by 1$$,
  $$values ('api.content_public_sunday_hymns'::text collate "C"), ('app.content_public_sunday_hymns')$$,
  'anon can execute only the public Sunday read pair');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname in (select proname from own_functions)
       and has_function_privilege('authenticated', p.oid, 'EXECUTE') order by 1$$,
  $$values ('api.content_my_hymn_favourites'::text collate "C"), ('api.content_public_sunday_hymns'),
           ('api.content_staff_sunday_hymns'), ('app.content_my_hymn_favourites'),
           ('app.content_public_sunday_hymns'), ('app.content_staff_sunday_hymns')$$,
  'authenticated gains only the member, public and staff read pairs');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api') and p.proname in (select proname from own_functions)
              and has_function_privilege('service_role', p.oid, 'EXECUTE')), 0,
  'service_role executes none of them');
select is_definer('app', 'content_my_hymn_favourites', array[]::text[], 'the member read body is a definer');
select isnt_definer('api', 'content_my_hymn_favourites', array[]::text[], 'its api wrapper is invoker');
select is_definer('app', 'content_public_sunday_hymns', array[]::text[], 'the public read body is a definer');
select isnt_definer('api', 'content_staff_sunday_hymns', array[]::text[], 'the staff api wrapper is invoker');
select results_eq($$select edition || ':' || hymn_count || ':' || chorus_count from app.content_hymn_editions$$,
  $$values ('bicc-tonga-2012:199:67'::text)$$, 'the built-in edition and its two ranges are recorded');
select results_eq($$select kind, editor_roles from app.content_kinds where kind = 'hymn_book'$$,
  $$values ('hymn_book'::text, array['admin', 'media']::text[])$$, 'hymn_book is edited by Admin and Media');
select results_eq($$select command || ':' || handler || ':' || creates from app.content_commands
                      where kind = 'hymn_book' order by 1$$,
  $$values ('content.clear_sunday_hymns:app.content_sunday_hymns_clear(uuid,bigint,jsonb):false'::text),
           ('content.remove_hymn_favourite:app.content_hymn_favourite_remove(uuid,bigint,jsonb):true'),
           ('content.save_hymn_favourite:app.content_hymn_favourite_save(uuid,bigint,jsonb):true'),
           ('content.set_sunday_hymns:app.content_sunday_hymns_set(uuid,bigint,jsonb):false')$$,
  'the four hymn_book commands are registered');
select results_eq($$select command from app.content_member_commands
                     where command like 'content.%hymn_favourite' order by 1$$,
  $$values ('content.remove_hymn_favourite'::text), ('content.save_hymn_favourite')$$,
  'the favourite commands are member commands');
select results_eq($$select kind || ':' || scope_kind || ':' || scope_id from app.content_kind_scopes where kind = 'hymn_book'$$,
  $$select 'hymn_book:worship_leader:' || list_id from app.content_sunday_hymn_lists$$,
  'the worship_leader scope on the one Sunday-list record edits hymn_book');
select results_eq($$select aggregate_type || ':' || handler from app.content_replay_scopes
                     where aggregate_type in ('content_hymn_favourite', 'content_sunday_hymns') order by 1$$,
  $$values ('content_hymn_favourite:app.content_hymn_favourite_in_scope(jsonb)'::text),
           ('content_sunday_hymns:app.content_sunday_hymns_in_scope(jsonb)')$$,
  'both aggregates register their replay recheck');
select results_eq($$select part || ':' || handler from app.content_erase_parts
                     where part in ('hymn_favourites', 'sunday_hymn_revisions') order by 1$$,
  $$values ('hymn_favourites:app.content_hymn_favourite_erase_part(jsonb)'::text),
           ('sunday_hymn_revisions:app.content_sunday_hymns_erase_part(jsonb)')$$,
  'both erase parts are registered');
select results_eq($$select scope_kind || ':' || module || ':' || target_hook from app.identity_scope_kinds where module = 'content'$$,
  $$values ('worship_leader:content:app.content_scope_target_ok(jsonb)'::text)$$,
  'Content registers the worship_leader scope kind with Identity');
select is((select count(*)::int from app.content_sunday_hymn_lists), 1, 'the church has one Sunday-list record');
select throws_ok($$insert into app.content_sunday_hymn_lists (list_id) values (gen_random_uuid())$$,
  '23505', null, 'and cannot get a second one');
select throws_ok($$select app.content_register_kind_scope('hymn_book', 'cell_leader', gen_random_uuid())$$,
  'PCTR1', null, 'a scope kind of another module cannot edit a Content kind');
select throws_ok($$select app.content_register_replay_scope('content_item', 'app.content_hymn_favourite_in_scope(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'content items keep the 6.1 replay recheck');
select throws_ok($$select app.content_register_replay_scope('content_x', 'app.content_hymn_favourite_erase_part(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a replay scope must answer a boolean');
select throws_ok($$select app.content_register_member_command('content.nope')$$,
  'PCTR1', null, 'only a registered command can be a member command');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'every object has an owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function pins search_path');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Favourites: an approved member's own -----------------------------------------------------------
create temp table f1 as select pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-12')) as r;
select is((select r -> 'data' from f1),
  '{"edition": "bicc-tonga-2012", "item": "hymn-12", "saved": true, "revision": 1}'::jsonb,
  'a member saves hymn 12');
select is((select r -> 'data' -> 'revision' from (select pg_temp.cmd(4, 'content.save_hymn_favourite', null,
            pg_temp.fav('hymn-12')) as r) x), '1'::jsonb, 'saving it again changes nothing');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('chorus-67'))), 'ok',
  'the last chorus can be saved');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-199'))), 'ok',
  'and the last hymn');
select is(pg_temp.items(4), 'chorus-67,hymn-12,hymn-199', 'the member reads their three saved items');
select is(pg_temp.items(4, 2) is not distinct from pg_temp.items(4), true, 'their second phone reads the same');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-200'))),
  'validation_failed|item=out_of_range', 'hymn 200 is not in the edition');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('chorus-68'))),
  'validation_failed|item=out_of_range', 'chorus 68 is not in the edition');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-0'))),
  'validation_failed|item=invalid', 'there is no hymn 0');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-012'))),
  'validation_failed|item=invalid', 'a number with a leading zero is refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('Hymn-1'))),
  'validation_failed|item=invalid', 'the id is lower case');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null,
  jsonb_build_object('edition', 'bicc-tonga-2012', 'item', 12))), 'validation_failed|item=invalid',
  'a bare number is refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-1', 'bicc-tonga-2099'))),
  'validation_failed|edition=unknown_edition', 'an unknown edition is refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', null, '{"item": "hymn-1", "title": "x"}')),
  'validation_failed|edition=required,title=unknown_field', 'the edition is required and no text is taken');
select is(pg_temp.err(pg_temp.cmd(4, 'content.save_hymn_favourite', 3, pg_temp.fav('hymn-1'))),
  'validation_failed|expected_revision=must_be_null', 'a favourite takes no expected revision');
select is(pg_temp.items(5), null, 'another member reads none of them');
select is(pg_temp.err(pg_temp.cmd(5, 'content.remove_hymn_favourite', null, pg_temp.fav('hymn-12'))), 'not_found',
  'and cannot remove the first member''s favourite');
select is(pg_temp.err(pg_temp.cmd(4, 'content.remove_hymn_favourite', null, pg_temp.fav('chorus-67'), gen_random_uuid(), 2)),
  'ok', 'the second phone removes chorus 67');
select is(pg_temp.items(4), 'hymn-12,hymn-199', 'and the first phone no longer lists it');
select is((select favourite_state || ':' || revision from app.content_hymn_favourites
            where member_id = pg_temp.mid(4) and item_kind = 'chorus' and item_number = 67),
  'removed:2', 'removal is a state change: the row stays');
select is((select r -> 'data' ->> 'saved' from (select pg_temp.cmd(4, 'content.remove_hymn_favourite', null,
            pg_temp.fav('chorus-67')) as r) x), 'false', 'removing it again changes nothing');
select is(pg_temp.err(pg_temp.cmd(4, 'content.remove_hymn_favourite', null, pg_temp.fav('hymn-5'))), 'not_found',
  'an item never saved cannot be removed');
select is((select r -> 'data' -> 'revision' from (select pg_temp.cmd(4, 'content.save_hymn_favourite', null,
            pg_temp.fav('chorus-67')) as r) x), '3'::jsonb, 'saving it again restores the row');
select is(pg_temp.err(pg_temp.cmd(6, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-1'))), 'forbidden',
  'a Pending account cannot save');
select is(pg_temp.read(6, 'select api.content_my_hymn_favourites()') #>> '{}', 'PT403|forbidden|not_linked',
  'nor read favourites');
select is(pg_temp.read(null, 'select api.content_my_hymn_favourites()') #>> '{}',
  '42501|permission denied for function content_my_hymn_favourites|', 'anon cannot call the member read');
select is(pg_temp.read(null, $q$select api.content_command('{"version": 1}'::jsonb)$q$) #>> '{}',
  '42501|permission denied for function content_command|', 'nor any command');
select is(pg_temp.read(1, 'select api.content_my_hymn_favourites()') -> 'favourites', '[]'::jsonb,
  'an Admin reads only their own (none): no read takes a member');
select is(pg_temp.read(2, 'select api.content_my_hymn_favourites()') -> 'favourites', '[]'::jsonb,
  'a Media member reads only their own (none)');
select is((select string_agg(k, ',' order by k) from jsonb_object_keys(
            pg_temp.read(4, 'select api.content_my_hymn_favourites()') -> 'favourites' -> 0) k),
  'edition,item,saved_at', 'a favourite carries the edition, the item id and when it was saved');
select is(pg_temp.read(4, 'select api.content_my_hymn_favourites()') -> 'truncated', 'false'::jsonb, 'not truncated');
-- Replay and the recheck.
create temp table rq as select gen_random_uuid() as id;
create temp table f2 as select pg_temp.cmd(5, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-7'), (select id from rq)) as r;
select is(pg_temp.cmd(5, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-7'), (select id from rq)),
  (select r from f2), 'a replay answers the stored result');
select is((select count(*)::int from app.content_hymn_favourites where member_id = pg_temp.mid(5)), 1,
  'and creates nothing twice');
select is(split_part(pg_temp.read(5, format('select to_jsonb(app.content_hymn_favourite_in_scope(%L::jsonb))',
            jsonb_build_object('aggregate_id', (select r ->> 'aggregate_id' from f2),
                               'actor', pg_temp.u(5)))) #>> '{}', '|', 1),
  '42501', 'the recheck is not callable by a client');
select set_config('request.jwt.claims', pg_temp.c(4)::text, true);
select is(app.content_hymn_favourite_in_scope(jsonb_build_object('aggregate_id',
  (select favourite_id from app.content_hymn_favourites where member_id = pg_temp.mid(5)))), false,
  'another member''s favourite is not in a member''s replay scope');
select set_config('request.jwt.claims', pg_temp.c(5)::text, true);
select is(app.content_hymn_favourite_in_scope(jsonb_build_object('aggregate_id',
  (select favourite_id from app.content_hymn_favourites where member_id = pg_temp.mid(5)))), true,
  'the member''s own favourite is');
-- A login hold.
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
values (pg_temp.mid(9), 'access_review', 'SYNTHETIC review', 'pgtap 6.8');
select is(pg_temp.err(pg_temp.cmd(9, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-1'))), 'forbidden',
  'a member on hold cannot save');
select is(split_part(pg_temp.read(9, 'select api.content_my_hymn_favourites()') #>> '{}', '|', 2), 'forbidden',
  'nor read');
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
values (pg_temp.mid(5), 'access_review', 'SYNTHETIC review', 'pgtap 6.8');
select is(pg_temp.err(pg_temp.cmd(5, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-7'), (select id from rq))),
  'forbidden', 'a replay is refused once the member is on hold');
update app.identity_holds set released_at = now(), released_by = 'pgtap 6.8' where member_id = pg_temp.mid(5);

-- Hymns for this Sunday: who may set it ---------------------------------------------------------
select is(pg_temp.read(2, 'select api.content_staff_sunday_hymns()') ->> 'capacity', 'media', 'Media reads the lists');
select is(pg_temp.read(2, 'select api.content_staff_sunday_hymns()') -> 'members', 'null'::jsonb,
  'but not the members to choose worship leaders from');
select is(pg_temp.read(1, 'select api.content_staff_sunday_hymns()') ->> 'capacity', 'admin', 'an Admin reads them');
select ok(jsonb_array_length(pg_temp.read(1, 'select api.content_staff_sunday_hymns()') -> 'members') >= 8,
  'and the approved members to choose from');
select is(pg_temp.read(1, 'select api.content_staff_sunday_hymns()') ->> 'this_sunday', pg_temp.sun(0),
  'this Sunday is church time');
select is(pg_temp.read(3, 'select api.content_staff_sunday_hymns()') #>> '{}', 'PT403|forbidden|not_granted',
  'a member who is not a worship leader cannot read them');
select is(pg_temp.read(7, 'select api.content_staff_sunday_hymns()') #>> '{}', 'PT403|forbidden|not_granted',
  'nor can a Pastor');
select is(pg_temp.err(pg_temp.grant_cmd(1, 'identity.grant_scope', pg_temp.mid(3), gen_random_uuid())),
  'validation_failed|scope_id=unknown', 'a worship_leader scope must target the Sunday-list record');
select is(pg_temp.err(pg_temp.grant_cmd(1, 'identity.grant_scope', pg_temp.mid(3), pg_temp.list_id())), 'ok',
  'an Admin makes a member a worship leader');
select is(pg_temp.err(pg_temp.grant_cmd(1, 'identity.grant_scope', pg_temp.mid(8), pg_temp.list_id())), 'ok',
  'and another');
select is(pg_temp.err(pg_temp.grant_cmd(2, 'identity.grant_scope', pg_temp.mid(4), pg_temp.list_id())), 'forbidden',
  'a Media member cannot');
select is(pg_temp.read(3, 'select api.content_staff_sunday_hymns()') ->> 'capacity', 'worship_leader',
  'the worship leader reads the lists at once');
select is((select string_agg(w ->> 'display_name', ',' order by w ->> 'display_name')
             from jsonb_array_elements(pg_temp.read(1, 'select api.content_staff_sunday_hymns()') -> 'worship_leaders') w),
  'SYNTHETIC Hymn Member 3,SYNTHETIC Hymn Member 8', 'the Admin sees both worship leaders');
create temp table s1 as select pg_temp.cmd(3, 'content.set_sunday_hymns', 1,
  pg_temp.sunday(pg_temp.sun(1), '["hymn-12", "chorus-3", "hymn-45"]')) as r;
select is(pg_temp.err((select r from s1)), 'ok', 'the worship leader sets next Sunday''s list');
select is((select (r -> 'data') - 'list_id' from s1),
  jsonb_build_object('revision', 2, 'sunday', pg_temp.sun(1), 'revision_no', 1), 'revision 1 of that Sunday');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 2, pg_temp.sunday(pg_temp.sun(0), '["hymn-1"]'))), 'ok',
  'a Media member sets this Sunday''s list');
select is(pg_temp.err(pg_temp.cmd(1, 'content.set_sunday_hymns', 3, pg_temp.sunday(pg_temp.sun(2), '["chorus-1"]'))), 'ok',
  'and an Admin the Sunday after');
select is((select string_agg(sunday::text || ':' || saved_capacity, ',' order by sunday) from app.content_sunday_hymn_revisions),
  pg_temp.sun(0) || ':media,' || pg_temp.sun(1) || ':worship_leader,' || pg_temp.sun(2) || ':admin',
  'each revision records the capacity it was saved in');
select is(pg_temp.err(pg_temp.cmd(3, 'content.set_sunday_hymns', 2, pg_temp.sunday(pg_temp.sun(1), '["hymn-2"]'))),
  'conflict', 'a stale revision conflicts');
select is((select r ->> 'current_revision' from (select pg_temp.cmd(3, 'content.set_sunday_hymns', 2,
            pg_temp.sunday(pg_temp.sun(1), '["hymn-2"]')) as r) x), '4', 'and names the current one');
select is(pg_temp.err(pg_temp.cmd(4, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-2"]'))),
  'forbidden', 'a plain member is refused');
select is(pg_temp.err(pg_temp.cmd(7, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-2"]'))),
  'forbidden', 'a Pastor is refused');
select is(pg_temp.err(pg_temp.cmd(6, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-2"]'))),
  'forbidden', 'a Pending account is refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.clear_sunday_hymns', 4, jsonb_build_object('sunday', pg_temp.sun(1)))),
  'forbidden', 'a plain member cannot clear a list');

-- Hymns for this Sunday: what is refused ------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4,
  pg_temp.sunday(to_char(app.content_this_sunday() + 6, 'YYYY-MM-DD'), '["hymn-1"]'))),
  'validation_failed|sunday=not_a_sunday', 'a Saturday is not a Sunday');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(-1), '["hymn-1"]'))),
  'validation_failed|sunday=past', 'last Sunday is past');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(53), '["hymn-1"]'))),
  'validation_failed|sunday=too_far', 'a Sunday more than 52 weeks ahead is too far');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday('2026-02-30', '["hymn-1"]'))),
  'validation_failed|sunday=invalid', 'a day that does not exist is invalid');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '[]'))),
  'validation_failed|items=required', 'a list has at least one item (clear empties it)');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1),
  (select jsonb_agg('hymn-' || n) from generate_series(1, 13) n)))),
  'validation_failed|items=too_many', 'at most 12 items');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-4", "hymn-4"]'))),
  'validation_failed|items=duplicate', 'an item appears once');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-4", "hymn-200"]'))),
  'validation_failed|items=out_of_range', 'every item must be in the edition');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["chorus-68"]'))),
  'validation_failed|items=out_of_range', 'choruses too');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["Amazing grace"]'))),
  'validation_failed|items=invalid', 'a title is not an item');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4, pg_temp.sunday(pg_temp.sun(1), '["hymn-1"]', 'other'))),
  'validation_failed|edition=unknown_edition', 'an unknown edition is refused');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', 4,
  pg_temp.sunday(pg_temp.sun(1), '["hymn-1"]') || '{"text": "x"}')),
  'validation_failed|text=unknown_field', 'no hymn text is taken');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_sunday_hymns', null, pg_temp.sunday(pg_temp.sun(1), '["hymn-1"]'))),
  'validation_failed|expected_revision=required', 'the list''s revision is required');
select is((select r -> 'data' ->> 'revision_no' from (select pg_temp.cmd(2, 'content.set_sunday_hymns', 4,
            pg_temp.sunday(pg_temp.sun(1), '["hymn-12", "chorus-3", "hymn-45"]')) as r) x), '1',
  'the same list again adds no revision');
select is(pg_temp.list_rev(), 4::bigint, 'and leaves the record''s revision');

-- Public and staff reads -------------------------------------------------------------------------
select is(pg_temp.read(null, 'select api.content_public_sunday_hymns()'),
  jsonb_build_object('sunday', pg_temp.sun(0), 'edition', 'bicc-tonga-2012', 'items', '["hymn-1"]'::jsonb,
                     'publication_revision', 1),
  'anyone reads this Sunday''s list: the date, the edition and the item ids only');
select is(pg_temp.read(6, 'select api.content_public_sunday_hymns()') -> 'items', '["hymn-1"]'::jsonb,
  'a Pending account reads it too');
select is((select string_agg(s ->> 'sunday' || '=' || (s ->> 'items') || ':' || (s ->> 'saved_by'), ';' order by s ->> 'sunday')
             from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_sunday_hymns()') -> 'sundays') s),
  pg_temp.sun(0) || '=["hymn-1"]:SYNTHETIC Hymn Member 2;' || pg_temp.sun(1)
    || '=["hymn-12", "chorus-3", "hymn-45"]:SYNTHETIC Hymn Member 3;' || pg_temp.sun(2) || '=["chorus-1"]:SYNTHETIC Hymn Member 1',
  'the editors read every Sunday with its list and who saved it');
select is(pg_temp.err(pg_temp.cmd(2, 'content.clear_sunday_hymns', 4, jsonb_build_object('sunday', pg_temp.sun(0)))), 'ok',
  'Media clears this Sunday''s list');
select is(pg_temp.read(null, 'select api.content_public_sunday_hymns()'),
  jsonb_build_object('sunday', pg_temp.sun(0), 'edition', null, 'items', '[]'::jsonb, 'publication_revision', null),
  'and the public read has no items');
select is(pg_temp.err(pg_temp.cmd(2, 'content.clear_sunday_hymns', 5, jsonb_build_object('sunday', pg_temp.sun(0)))),
  'validation_failed|sunday=not_set', 'a cleared list cannot be cleared again');
select is(pg_temp.err(pg_temp.cmd(2, 'content.clear_sunday_hymns', 5, jsonb_build_object('sunday', pg_temp.sun(3)))),
  'validation_failed|sunday=not_set', 'nor a Sunday that was never set');
select is((select count(*)::int from app.content_sunday_hymn_revisions where sunday = app.content_this_sunday()), 2,
  'the cleared list is a new revision; the old one stays');
select throws_ok($$update app.content_sunday_hymn_revisions set item_count = 0, edition = null where revision_no = 1$$,
  'PCNT1', null, 'a saved revision cannot change');
select throws_ok($$update app.content_sunday_hymn_items set item_number = 2$$,
  'PCNT1', null, 'nor its items');

-- Revocation, replay and no leak to other kinds ---------------------------------------------------------
create temp table rq2 as select gen_random_uuid() as id;
create temp table s2 as select pg_temp.cmd(3, 'content.set_sunday_hymns', 5,
  pg_temp.sunday(pg_temp.sun(1), '["hymn-12", "hymn-45"]'), (select id from rq2)) as r;
select is(pg_temp.err((select r from s2)), 'ok', 'the worship leader changes next Sunday''s list');
select is(pg_temp.cmd(3, 'content.set_sunday_hymns', 5, pg_temp.sunday(pg_temp.sun(1), '["hymn-12", "hymn-45"]'),
  (select id from rq2)), (select r from s2), 'its replay answers the stored result');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null, jsonb_build_object(
  'title', 'SYNTHETIC Worship night', 'description', 'SYNTHETIC', 'location', 'SYNTHETIC hall',
  'starts_at', to_char((now() + interval '3 days') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'ends_at', to_char((now() + interval '3 days 2 hours') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  'forbidden', 'the worship leader scope edits no other kind');
select is(pg_temp.read(3, 'select api.content_staff_events()') #>> '{}', 'PT403|forbidden|not_granted',
  'nor reads another kind''s staff list');
select is(app.content_editor_capacity(pg_temp.mid(3), 'event'), null, 'it is no capacity for events');
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator)
values (pg_temp.mid(5), 'worship_leader', pg_temp.list_id(), 'israel');
update app.identity_grants set scope_id = gen_random_uuid() where member_id = pg_temp.mid(5) and scope_kind = 'worship_leader';
select is(app.content_editor_capacity(pg_temp.mid(5), 'hymn_book'), null,
  'a worship_leader grant on another record gives nothing');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where member_id = pg_temp.mid(3) and scope_kind = 'worship_leader';
select is(pg_temp.err(pg_temp.cmd(3, 'content.set_sunday_hymns', 6, pg_temp.sunday(pg_temp.sun(1), '["hymn-9"]'))),
  'forbidden', 'a revoked worship leader is refused at once');
select is(pg_temp.err(pg_temp.cmd(3, 'content.set_sunday_hymns', 5, pg_temp.sunday(pg_temp.sun(1), '["hymn-12", "hymn-45"]'),
  (select id from rq2))), 'forbidden', 'and their replay too');
select is(pg_temp.read(3, 'select api.content_staff_sunday_hymns()') #>> '{}', 'PT403|forbidden|not_granted',
  'and the lists are closed to them');
select set_config('request.jwt.claims', pg_temp.c(3)::text, true);
select is(app.content_sunday_hymns_in_scope(jsonb_build_object('aggregate_id', pg_temp.list_id())), false,
  'the Sunday list is no longer in the revoked worship leader''s replay scope');
select set_config('request.jwt.claims', pg_temp.c(2)::text, true);
select is(app.content_sunday_hymns_in_scope(jsonb_build_object('aggregate_id', pg_temp.list_id())), true,
  'it stays in a Media member''s');

-- Deletion: favourites erased, Sunday attribution anonymised ---------------------------------------------
select is(pg_temp.err(pg_temp.cmd(8, 'content.save_hymn_favourite', null, pg_temp.fav('hymn-3'))), 'ok',
  'member E saves a hymn');
select is(pg_temp.err(pg_temp.cmd(8, 'content.set_sunday_hymns', 6, pg_temp.sunday(pg_temp.sun(4), '["hymn-3"]'))), 'ok',
  'and, as a worship leader, sets a list');
select is(app.content_hymn_favourite_erase_part(jsonb_build_object('member_id', pg_temp.mid(8),
  'account_id', pg_temp.u(8), 'phase', 'check')), 1, 'the favourites check counts E''s favourite');
select is(app.content_sunday_hymns_erase_part(jsonb_build_object('member_id', pg_temp.mid(8),
  'account_id', pg_temp.u(8), 'phase', 'check')), 1, 'the Sunday check counts E''s revision');
-- Without the _rows file the purge is a fail-closed stub: the erase step is refused and nothing changes.
create temp table real_purge as
  select pg_get_functiondef('app.content_hymn_favourite_purge_rows(uuid)'::regprocedure) as def;
select ok((select def like '%delete from app.content_hymn_favourites f where f.member_id = p_member_id%' from real_purge),
  'locally the _rows body is in place');
create or replace function app.content_hymn_favourite_purge_rows(p_member_id uuid)
returns integer language plpgsql set search_path = '' as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;
select throws_ok(format($q$select app.identity_call_deletion_hooks(%L::uuid, %L::uuid, gen_random_uuid(), 'erase')$q$,
                        pg_temp.mid(8), pg_temp.u(8)),
  'PCMD1', 'unavailable', 'with the stub (staging before the _rows file) the erase step fails closed');
select is((select count(*)::int from app.content_hymn_favourites where member_id = pg_temp.mid(8)), 1,
  'and E''s favourite is still there');
do $$ begin execute (select def from real_purge); end $$;
select is((select h ->> 'remaining' from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(8), pg_temp.u(8), gen_random_uuid(), 'erase')) h where h ->> 'module' = 'content'),
  '0', 'with the _rows body, erase leaves nothing of E in Content');
select is((select h ->> 'remaining' from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(8), pg_temp.u(8), gen_random_uuid(), 'check')) h where h ->> 'module' = 'content'),
  '0', 'and the deletion check answers 0');
select is((select count(*)::int from app.content_hymn_favourites where member_id = pg_temp.mid(8)), 0,
  'E''s favourites are deleted');
select is((select s ->> 'saved_by' from jsonb_array_elements(pg_temp.read(2, 'select api.content_staff_sunday_hymns()') -> 'sundays') s
            where s ->> 'sunday' = pg_temp.sun(4)), 'Former member', 'E''s list stays and reads as a former member''s');
select is(pg_temp.items(4), 'chorus-67,hymn-12,hymn-199', 'another member''s favourites are untouched');

select * from finish();
rollback;
