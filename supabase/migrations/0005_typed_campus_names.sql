-- Allow participants to type a campus name, while retaining campus_id for existing records.
alter table profiles add column campus_name text;

update profiles p
set campus_name = c.name
from campuses c
where p.campus_id = c.id and p.campus_name is null;

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path=public, pg_temp as $$
declare
  v_campus_name text := nullif(btrim(new.raw_user_meta_data->>'campus_name'), '');
  v_campus_id int;
begin
  if v_campus_name is null and nullif(new.raw_user_meta_data->>'campus_id', '') is not null then
    v_campus_id := (new.raw_user_meta_data->>'campus_id')::int;
    select name into v_campus_name
    from campuses
    where id = v_campus_id and is_active;
  end if;
  if v_campus_name is null then
    raise exception 'campus name is required';
  end if;
  if length(v_campus_name) > 100 then
    raise exception 'campus name must be 100 characters or fewer';
  end if;

  if v_campus_id is null then
    select id into v_campus_id
    from campuses
    where is_active and lower(btrim(name)) = lower(v_campus_name)
    order by id
    limit 1;
  end if;

  insert into profiles (
    id, full_name, normalized_email, normalized_phone, campus_id, campus_name, account_status
  )
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',
    lower(trim(new.email)),
    nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'phone',''), '[\s().-]', '', 'g'), ''),
    v_campus_id,
    v_campus_name,
    'pending_verification'
  );
  return new;
end $$;

create or replace view public_gallery as
  select s.id,
         split_part(p.full_name,' ',1) || ' ' ||
           left(coalesce(nullif(split_part(p.full_name,' ',2),''),'.'),1) as display_name,
         coalesce(nullif(btrim(p.campus_name),''), c.name) as campus,
         s.title, s.description, s.primary_photo_path, s.secondary_photo_path, s.submitted_at
  from submissions s
  join profiles p on p.id = s.participant_id
  left join campuses c on c.id = p.campus_id
  where s.status = 'approved' and p.account_status = 'active';

create or replace function admin_stats() returns jsonb
language plpgsql stable security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  return jsonb_build_object(
    'participants',(select count(*) from profiles where role='participant'),
    'approved',(select count(*) from submissions where status='approved'),
    'pending',(select count(*) from submissions where status='pending'),
    'rejected',(select count(*) from submissions where status='rejected'),
    'votes',(select count(*) from votes where status='valid'),
    'by_campus',coalesce((
      select jsonb_object_agg(n,c)
      from (
        select coalesce(nullif(btrim(p.campus_name),''), ca.name, '—') n, count(*) c
        from profiles p
        left join campuses ca on ca.id=p.campus_id
        where p.role='participant'
        group by 1
      ) t
    ),'{}'::jsonb)
  );
end $$;

create or replace function admin_vote_summary()
returns table(entry text, campus text, valid_votes bigint, invalidated_votes bigint)
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  return query
    select coalesce(s.title,p.full_name),
           coalesce(nullif(btrim(p.campus_name),''), c.name, '—'),
           count(v.id) filter (where v.status='valid'),
           count(v.id) filter (where v.status='invalidated')
    from submissions s
    join profiles p on p.id=s.participant_id
    left join campuses c on c.id=p.campus_id
    left join votes v on v.submission_id=s.id
    where s.status='approved'
    group by s.id,p.full_name,p.campus_name,c.name
    order by 3 desc;
end $$;

create or replace function admin_duplicates()
returns table(reason text, profile_id uuid, full_name text, email text, phone text, campus text)
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  return query
  with k as (
    select p.id, 'same name'::text r,
      lower(regexp_replace(trim(p.full_name),'\s+',' ','g')) key
    from profiles p where p.role='participant'
    union all
    select p.id,'same phone ending',right(p.normalized_phone,8)
    from profiles p where p.normalized_phone is not null and p.role='participant'
    union all
    select p.id,'same email ignoring dots/+tag',
      regexp_replace(split_part(split_part(p.normalized_email,'@',1),'+',1),'\.','','g')
      ||'@'||split_part(p.normalized_email,'@',2)
    from profiles p where p.role='participant'
  )
  select k.r, p.id, p.full_name, p.normalized_email, p.normalized_phone,
         coalesce(nullif(btrim(p.campus_name),''), c.name, '—')
  from k
  join profiles p on p.id=k.id
  left join campuses c on c.id=p.campus_id
  where (k.r,k.key) in (
    select k2.r,k2.key from k k2 group by k2.r,k2.key having count(*)>1
  )
  order by k.r,k.key;
end $$;
