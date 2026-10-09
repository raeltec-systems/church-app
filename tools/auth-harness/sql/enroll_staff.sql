-- Operator write (not an observation), run out of band through the Supabase
-- MCP by the restricted operator: enrol ONE existing synthetic Auth account
-- as harness staff. The operator token cannot do this (the Edge Function
-- refuses provision role "staff"). Replace :email with the account's
-- plus-address; it must match israelmuyoba+bicauth-%@gmail.com.
insert into harness.rc_staff (auth_user_id)
select u.id from auth.users u
 where u.email = ':email' and u.email like 'israelmuyoba+bicauth-%@gmail.com'
on conflict do nothing
returning 'h:' || left(encode(sha256(auth_user_id::text::bytea), 'hex'), 10) as staff;
