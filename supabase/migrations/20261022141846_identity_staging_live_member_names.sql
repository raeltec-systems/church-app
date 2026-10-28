-- Owner decision 2026-10-22: interactive membership tests on staging may use real names.
-- Automated fixtures remain SYNTHETIC and production still requires the Q4 approval.
do $$
declare
  v_definition text;
  v_search constant text := $needle$or (not app.policy_is_open('q4_personal_data') and full_name !~ '^SYNTHETIC ') then$needle$;
  v_replace constant text := $replacement$or (not app.policy_is_open('q4_personal_data') and app.platform_current_environment() <> 'staging' and full_name !~ '^SYNTHETIC ') then$replacement$;
begin
  v_definition := pg_get_functiondef('app.identity_application_name(jsonb,jsonb)'::regprocedure);
  if length(v_definition) - length(replace(v_definition, v_search, '')) <> length(v_search) then
    raise exception 'identity_application_name source changed; refusing an unexpected rewrite';
  end if;
  execute replace(v_definition, v_search, v_replace);
end;
$$;
