begin;
select plan(4);

select app.platform_set_environment('staging', 'pgtap live-name test');
create temp table tested_name as
  select * from app.identity_application_name(to_jsonb('Preview Applicant'::text), '{}'::jsonb);

select is(app.platform_current_environment(), 'staging', 'the name test runs with the staging marker');
select ok(not app.policy_is_open('q4_personal_data'), 'the real-name path does not open Q4');
select is((select errors from tested_name), '{}'::jsonb,
  'staging accepts a non-prefixed name for live owner testing');
select is((select full_name from tested_name), 'Preview Applicant',
  'staging preserves the name entered by the member');

select * from finish();
rollback;
