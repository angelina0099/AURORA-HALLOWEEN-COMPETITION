-- Vote invalidation, vote inspection, duplicate review, vote summary (all admin-only and audited).
create function admin_invalidate_vote(p_vote uuid, p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin perform _admin_guard();
  if coalesce(trim(p_reason),'')='' then raise exception 'reason required'; end if;
  update votes set status='invalidated' where id=p_vote;
  insert into audit_logs(actor_id,action,target_table,target_id,reason) values (auth.uid(),'vote_invalidated','votes',p_vote::text,p_reason);
end $$;

create function admin_vote_records() returns table(vote_id uuid, voter text, entry text, vote_status text, voted_at timestamptz)
language plpgsql security definer set search_path=public, pg_temp as $$
begin perform _admin_guard();
  insert into audit_logs(actor_id,action,target_table,reason) values (auth.uid(),'votes_inspected','votes','integrity review');
  return query select v.id, pv.full_name, coalesce(s.title,ps.full_name), v.status, v.created_at
    from votes v join profiles pv on pv.id=v.voter_id join submissions s on s.id=v.submission_id
    join profiles ps on ps.id=s.participant_id order by v.created_at desc;
end $$;

create function admin_vote_summary() returns table(entry text, campus text, valid_votes bigint, invalidated_votes bigint)
language plpgsql security definer set search_path=public, pg_temp as $$
begin perform _admin_guard();
  return query select coalesce(s.title,p.full_name), c.name,
    count(v.id) filter (where v.status='valid'), count(v.id) filter (where v.status='invalidated')
    from submissions s join profiles p on p.id=s.participant_id left join campuses c on c.id=p.campus_id
    left join votes v on v.submission_id=s.id where s.status='approved' group by s.id,p.full_name,c.name order by 3 desc;
end $$;

-- Suspected duplicates: same name, same last-8 phone digits, or same email ignoring dots/+tags. Review only; never auto-ban.
create function admin_duplicates() returns table(reason text, profile_id uuid, full_name text, email text, phone text, campus text)
language plpgsql security definer set search_path=public, pg_temp as $$
begin perform _admin_guard();
  return query
  with k as (
    select p.id, 'same name'::text r, lower(regexp_replace(trim(p.full_name),'\s+',' ','g')) key from profiles p where p.role='participant'
    union all select p.id,'same phone ending', right(p.normalized_phone,8) from profiles p where p.normalized_phone is not null and p.role='participant'
    union all select p.id,'same email ignoring dots/+tag', regexp_replace(split_part(split_part(p.normalized_email,'@',1),'+',1),'\.','','g')||'@'||split_part(p.normalized_email,'@',2) from profiles p where p.role='participant')
  select k.r, p.id, p.full_name, p.normalized_email, p.normalized_phone, c.name
  from k join profiles p on p.id=k.id left join campuses c on c.id=p.campus_id
  where (k.r,k.key) in (select k2.r,k2.key from k k2 group by k2.r,k2.key having count(*)>1) order by k.r, k.key;
end $$;
revoke all on function
  admin_invalidate_vote(uuid, text),
  admin_vote_records(),
  admin_vote_summary(),
  admin_duplicates()
from public, anon;
grant execute on function
  admin_invalidate_vote(uuid, text),
  admin_vote_records(),
  admin_vote_summary(),
  admin_duplicates()
to authenticated;
