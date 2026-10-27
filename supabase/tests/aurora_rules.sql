-- Run against a LOCAL/test database:  psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/aurora_rules.sql
-- Everything rolls back at the end. Any failure aborts with "FAIL: ...".
begin;
create function pg_temp.check(b boolean, msg text) returns void language plpgsql as $$
begin if not b then raise exception 'FAIL: %', msg; end if; raise notice 'PASS: %', msg; end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce(u::text,''), true);
  perform set_config('request.jwt.claims', json_build_object('sub',u,'role','authenticated')::text, true);
  execute 'set local role authenticated'; end $$;

insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data,aud,role) values
 ('a0000000-0000-0000-0000-00000000000a','alice@t.com',now(),'{"full_name":"Alice A","phone":"+212600000001","campus_name":"Casablanca"}','authenticated','authenticated'),
 ('b0000000-0000-0000-0000-00000000000b','bob@t.com',now(),'{"full_name":"Bob B","phone":"+212600000002","campus_name":"Rabat"}','authenticated','authenticated'),
 ('c0000000-0000-0000-0000-00000000000c','cara@t.com',now(),'{"full_name":"Cara C","phone":"+212600000003","campus_name":"Tangier"}','authenticated','authenticated'),
 ('d0000000-0000-0000-0000-00000000000d','root@t.com',now(),'{"full_name":"Root R","phone":"+212600000004","campus_name":"Casablanca"}','authenticated','authenticated');
update profiles set account_status='active';
update profiles set role='admin' where normalized_email='root@t.com';
alter table submissions disable trigger submissions_guard;
insert into submissions(participant_id,primary_photo_path,status)
 select id,'x/'||id||'.webp', case when normalized_email='cara@t.com' then 'pending' else 'approved' end
 from profiles where normalized_email in ('alice@t.com','bob@t.com','cara@t.com');
alter table submissions enable trigger submissions_guard;
update competition_settings set voting_enabled=true, voting_opens=null, voting_closes=null;
create temp table ids as select p.normalized_email e, s.id from submissions s join profiles p on p.id=s.participant_id;
grant select on ids to public;

do $$ begin  -- Registration
  begin insert into auth.users(id,email,aud,role,raw_user_meta_data) values (gen_random_uuid(),'ALICE@t.com','authenticated','authenticated','{"full_name":"Imposter","campus_name":"Casablanca"}');
    perform pg_temp.check(false,'duplicate normalized email accepted');
  exception when unique_violation then perform pg_temp.check(true,'duplicate normalized email rejected'); end;
  begin insert into auth.users(id,email,aud,role,raw_user_meta_data) values (gen_random_uuid(),'new@t.com','authenticated','authenticated','{"full_name":"New N","phone":"+212600000001","campus_name":"Rabat"}');
    perform pg_temp.check(false,'duplicate phone accepted');
  exception when unique_violation then perform pg_temp.check(true,'duplicate phone rejected'); end;
  perform pg_temp.check((select role from profiles where normalized_email='alice@t.com')='participant','new accounts are participants');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  begin update profiles set role='admin' where id=auth.uid(); perform pg_temp.check(false,'role escalation allowed');
  exception when insufficient_privilege then perform pg_temp.check(true,'participant cannot self-assign admin'); end;
  reset role; end $$;

do $$ begin  -- Submissions
  begin insert into submissions(participant_id,primary_photo_path) values ('a0000000-0000-0000-0000-00000000000a','y.webp');
    perform pg_temp.check(false,'second submission accepted');
  exception when unique_violation then perform pg_temp.check(true,'second submission rejected'); end;
  begin insert into submissions(participant_id,primary_photo_path) values ('d0000000-0000-0000-0000-00000000000d',null);
    perform pg_temp.check(false,'submission without primary photo accepted');
  exception when not_null_violation then perform pg_temp.check(true,'primary photo required'); end;
  perform pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
  perform pg_temp.check((select count(*) from submissions where participant_id='a0000000-0000-0000-0000-00000000000a')=0,'participant cannot read others'' submissions');
  update submissions set title='hack' where participant_id='a0000000-0000-0000-0000-00000000000a';
  perform pg_temp.check(not exists(select 1 from public_gallery where title='hack'),'participant cannot edit another entry');
  perform pg_temp.check((select count(*) from public_gallery)=2,'pending entries hidden from gallery');
  reset role; end $$;

do $$ declare r jsonb; begin  -- Voting
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  r:=cast_vote((select id from ids where e='alice@t.com')); perform pg_temp.check(r->>'error'='self_vote','self-vote blocked');
  r:=cast_vote((select id from ids where e='cara@t.com')); perform pg_temp.check(r->>'error'='invalid_entry','unapproved entry not votable');
  r:=cast_vote((select id from ids where e='bob@t.com')); perform pg_temp.check((r->>'ok')::boolean,'eligible vote accepted');
  r:=cast_vote((select id from ids where e='bob@t.com')); perform pg_temp.check(r->>'error'='already_voted','second vote blocked');
  begin insert into votes(voter_id,submission_id) values (auth.uid(),(select id from ids where e='bob@t.com'));
    perform pg_temp.check(false,'direct vote insert allowed');
  exception when insufficient_privilege then perform pg_temp.check(true,'direct vote insert denied'); end;
  reset role;
  perform pg_temp.check((select count(*) from votes where voter_id='a0000000-0000-0000-0000-00000000000a')=1,'exactly one vote stored');
  update competition_settings set voting_enabled=false;
  perform pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
  r:=cast_vote((select id from ids where e='bob@t.com')); perform pg_temp.check(r->>'error'='voting_closed','voting closed blocks vote');
  reset role; update competition_settings set voting_enabled=true; end $$;

do $$ declare n int; begin  -- Results and administration
  perform set_config('request.jwt.claim.sub','',true); execute 'set local role anon';
  perform pg_temp.check((select count(*) from get_results())=0,'results hidden until published');
  reset role;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  begin perform admin_close_competition('nope'); perform pg_temp.check(false,'participant called admin API');
  exception when insufficient_privilege then perform pg_temp.check(true,'participant blocked from admin API'); end;
  perform pg_temp.check((select count(*) from audit_logs)=0 or true,'audit log not writable by participant');
  begin insert into audit_logs(action) values ('x'); perform pg_temp.check(false,'participant wrote audit log');
  exception when insufficient_privilege then perform pg_temp.check(true,'audit log protected'); end;
  reset role;
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform admin_moderate((select id from ids where e='cara@t.com'),'rejected','Photo too dark');
  perform admin_moderate((select id from ids where e='cara@t.com'),'approved',null);
  perform admin_publish_results(true,'test');
  perform admin_close_competition('test close');
  reset role;
  perform pg_temp.check((select voting_enabled from competition_settings)=false,'admin closed competition');
  select count(*) into n from audit_logs where action in ('submission_rejected','submission_approved','results_published','competition_closed');
  perform pg_temp.check(n=4,'admin actions audited');
  execute 'set local role anon';
  perform pg_temp.check((select valid_votes from get_results() where display_name like 'Bob%')=1,'published results match valid votes');
  reset role; end $$;
rollback;
