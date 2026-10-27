-- AURORA Halloween Makeup Competition — core schema, RLS, and voting rules
create extension if not exists pgcrypto;

create table campuses (
  id serial primary key, name text not null unique,
  is_active boolean not null default true, created_at timestamptz not null default now());

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 2 and 100),
  normalized_email text not null unique,
  normalized_phone text unique check (normalized_phone ~ '^\+[1-9][0-9]{7,14}$'),
  campus_id int references campuses(id),
  role text not null default 'participant' check (role in ('participant','admin')),
  account_status text not null default 'active' check (account_status in ('active','suspended','pending_verification')),
  suspension_reason text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());

create table competition_settings (
  id int primary key default 1 check (id = 1),           -- single active row
  title text not null default 'AURORA Halloween Makeup Competition',
  registration_opens timestamptz, registration_closes timestamptz,
  submission_deadline timestamptz,
  voting_enabled boolean not null default false,
  voting_opens timestamptz, voting_closes timestamptz,
  hide_results_until_close boolean not null default true,
  results_published boolean not null default false,
  allow_edits boolean not null default true,
  allow_vote_change boolean not null default false,
  max_photo_mb int not null default 5 check (max_photo_mb between 1 and 20),
  tie_policy text not null default 'share_rank' check (tie_policy in ('share_rank','admin_tiebreak')),
  contact_email text,
  check (registration_closes is null or registration_opens is null or registration_closes > registration_opens),
  check (voting_closes is null or voting_opens is null or voting_closes > voting_opens),
  check (voting_opens is null or submission_deadline is null or voting_opens >= submission_deadline));
insert into competition_settings default values;

create table submissions (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null unique references profiles(id) on delete cascade, -- one entry each
  title text check (length(title) <= 80), description text check (length(description) <= 1000),
  primary_photo_path text not null, secondary_photo_path text,                  -- max two photos
  status text not null default 'draft' check (status in ('draft','pending','approved','rejected')),
  locked boolean not null default false,
  rejection_reason text, moderation_note text, flagged boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  check (status <> 'rejected' or rejection_reason is not null));
create index on submissions(status);

create table votes (
  id uuid primary key default gen_random_uuid(),
  voter_id uuid not null unique references profiles(id),     -- one vote per account
  submission_id uuid not null references submissions(id),
  status text not null default 'valid' check (status in ('valid','invalidated')),
  created_at timestamptz not null default now());
create index on votes(submission_id) where status = 'valid';

create table audit_logs (
  id bigserial primary key, actor_id uuid references profiles(id),
  action text not null, target_table text, target_id text, reason text,
  details jsonb, created_at timestamptz not null default now());

-- ---------- helpers ----------
create function is_admin() returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and account_status = 'active') $$;

-- Profile is created from auth signup; role is ALWAYS participant (never read from client metadata).
create function handle_new_user() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into profiles (id, full_name, normalized_email, normalized_phone, campus_id, account_status)
  values (new.id, new.raw_user_meta_data->>'full_name', lower(trim(new.email)),
          nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'phone',''), '[\s().-]', '', 'g'), ''),
          nullif(new.raw_user_meta_data->>'campus_id','')::int, 'pending_verification');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create function sync_verification() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.email_confirmed_at is not null and old.email_confirmed_at is null then
    update profiles set account_status = 'active', updated_at = now()
    where id = new.id and account_status = 'pending_verification';
  end if; return new;
end $$;
create trigger on_auth_user_verified after update on auth.users for each row execute function sync_verification();

-- ---------- submission guard (participants cannot self-approve or change owner) ----------
create function guard_submission() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare s competition_settings;
begin
  if is_admin() then return new; end if;
  select * into s from competition_settings;
  if tg_op = 'INSERT' then
    if new.status not in ('draft','pending') then raise exception 'invalid status'; end if;
  else
    if new.participant_id <> old.participant_id then raise exception 'ownership is immutable'; end if;
    if old.locked or not s.allow_edits or (s.submission_deadline is not null and now() > s.submission_deadline) then
      raise exception 'submission is locked'; end if;
    if new.status not in ('draft','pending') then raise exception 'invalid status'; end if;
    new.locked := old.locked; new.rejection_reason := old.rejection_reason;
    new.moderation_note := old.moderation_note; new.flagged := old.flagged;
  end if;
  if s.submission_deadline is not null and now() > s.submission_deadline and tg_op = 'INSERT' then
    raise exception 'submission deadline passed'; end if;
  new.updated_at := now(); return new;
end $$;
create trigger submissions_guard before insert or update on submissions for each row execute function guard_submission();

-- Defense in depth: self-vote blocked at table level too.
create function block_self_vote() returns trigger language plpgsql as $$
begin
  if exists (select 1 from submissions where id = new.submission_id and participant_id = new.voter_id)
  then raise exception 'self-vote not allowed'; end if; return new;
end $$;
create trigger votes_no_self before insert or update on votes for each row execute function block_self_vote();

-- ---------- THE voting endpoint (atomic, server-side) ----------
create function cast_vote(p_submission uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); s competition_settings; p profiles; sub submissions; v_ok boolean;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_authenticated'); end if;
  select * into p from profiles where id = uid;
  select * into s from competition_settings;
  select exists (select 1 from auth.users where id = uid and email_confirmed_at is not null) into v_ok;
  if p.id is null or p.account_status <> 'active' or not v_ok then
    return jsonb_build_object('ok', false, 'error', 'account_not_eligible'); end if;
  if not s.voting_enabled or (s.voting_opens is not null and now() < s.voting_opens)
     or (s.voting_closes is not null and now() > s.voting_closes) then
    insert into audit_logs(actor_id, action, target_id, reason) values (uid,'vote_rejected',p_submission::text,'voting_closed');
    return jsonb_build_object('ok', false, 'error', 'voting_closed'); end if;
  select * into sub from submissions where id = p_submission;
  if sub.id is null or sub.status <> 'approved' then
    insert into audit_logs(actor_id, action, target_id, reason) values (uid,'vote_rejected',p_submission::text,'not_approved');
    return jsonb_build_object('ok', false, 'error', 'invalid_entry'); end if;
  if sub.participant_id = uid then
    insert into audit_logs(actor_id, action, target_id, reason) values (uid,'suspicious_self_vote',p_submission::text,'self_vote_attempt');
    return jsonb_build_object('ok', false, 'error', 'self_vote'); end if;
  begin
    if s.allow_vote_change then
      insert into votes(voter_id, submission_id) values (uid, p_submission)
      on conflict (voter_id) do update set submission_id = excluded.submission_id, created_at = now() where votes.status = 'valid';
    else
      insert into votes(voter_id, submission_id) values (uid, p_submission);
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'already_voted');
  end;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function cast_vote(uuid) from public;
grant execute on function cast_vote(uuid) to authenticated;

-- Results: rank = competition ranking (ties share a rank); hidden until published.
create function get_results() returns table(submission_id uuid, display_name text, title text, valid_votes bigint, rank bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id, split_part(p.full_name,' ',1) || ' ' || left(coalesce(nullif(split_part(p.full_name,' ',2),''),'.'),1) || '.',
         s.title, count(v.id), rank() over (order by count(v.id) desc)
  from submissions s join profiles p on p.id = s.participant_id
  left join votes v on v.submission_id = s.id and v.status = 'valid'
  where s.status = 'approved'
    and ((select results_published from competition_settings) or is_admin())
  group by s.id, p.full_name, s.title order by 5, 4 desc $$;
grant execute on function get_results() to anon, authenticated;

-- Public gallery: approved entries only, no email/phone/internal profile data.
create view public_gallery as
  select s.id, split_part(p.full_name,' ',1) || ' ' || left(coalesce(nullif(split_part(p.full_name,' ',2),''),'.'),1) || '.' as display_name,
         c.name as campus, s.title, s.description, s.primary_photo_path, s.secondary_photo_path, s.submitted_at
  from submissions s join profiles p on p.id = s.participant_id left join campuses c on c.id = p.campus_id
  where s.status = 'approved' and p.account_status = 'active';
grant select on public_gallery to anon, authenticated;

-- ---------- Row Level Security ----------
alter table campuses enable row level security;  alter table profiles enable row level security;
alter table competition_settings enable row level security; alter table submissions enable row level security;
alter table votes enable row level security;     alter table audit_logs enable row level security;

create policy campuses_read on campuses for select using (is_active or is_admin());
create policy campuses_admin on campuses for all using (is_admin()) with check (is_admin());
create policy settings_read on competition_settings for select using (true);
create policy settings_admin on competition_settings for update using (is_admin()) with check (is_admin());

create policy profiles_self_read on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_self_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_admin_update on profiles for update using (is_admin()) with check (is_admin());
revoke update on profiles from authenticated;                       -- column-level grants below
grant update (full_name, campus_id) on profiles to authenticated;   -- role/status/email are NOT client-writable
-- (admins change status/role via service-role server actions that write audit_logs)

create policy subs_own_read on submissions for select using (participant_id = auth.uid() or is_admin());
create policy subs_own_insert on submissions for insert with check (participant_id = auth.uid());
create policy subs_own_update on submissions for update using (participant_id = auth.uid()) with check (participant_id = auth.uid());
create policy subs_admin on submissions for all using (is_admin()) with check (is_admin());

create policy votes_own_read on votes for select using (voter_id = auth.uid() or is_admin());
revoke insert, update, delete on votes from authenticated, anon;    -- votes ONLY via cast_vote()
create policy votes_admin_update on votes for update using (is_admin()) with check (is_admin());
grant update (status) on votes to authenticated;                    -- RLS limits this to admins

create policy audit_admin_read on audit_logs for select using (is_admin());
revoke insert, update, delete on audit_logs from authenticated, anon;

-- ---------- Storage (private bucket; files live under <user_id>/...) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions','submissions', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy photos_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);
create policy photos_modify on storage.objects for update to authenticated
  using (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);
create policy photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);
create policy photos_read on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and ((storage.foldername(name))[1] = auth.uid()::text or is_admin()));
-- Approved photos reach the public gallery through short-lived signed URLs issued server-side.
