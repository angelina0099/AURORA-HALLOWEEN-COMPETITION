-- Admin actions: every one checks is_admin() and writes to audit_logs.
create function _admin_guard() returns void language plpgsql security definer set search_path=public, pg_temp as $$
begin if not is_admin() then raise exception 'forbidden' using errcode='42501'; end if; end $$;

create function admin_moderate(p_id uuid, p_status text, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  if p_status not in ('approved','rejected','pending') then raise exception 'bad status'; end if;
  if p_status='rejected' and coalesce(trim(p_reason),'')='' then raise exception 'rejection reason required'; end if;
  update submissions set status=p_status, rejection_reason=case when p_status='rejected' then p_reason end,
    moderation_note=coalesce(p_note,moderation_note), updated_at=now() where id=p_id;
  insert into audit_logs(actor_id,action,target_table,target_id,reason) values (auth.uid(),'submission_'||p_status,'submissions',p_id::text,p_reason);
end $$;

-- CLOSE THE COMPETITION: stops voting immediately and freezes submissions.
create function admin_close_competition(p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  if coalesce(trim(p_reason),'')='' then raise exception 'reason required'; end if;
  update competition_settings set voting_enabled=false,
    voting_closes=case when voting_opens is null or voting_opens<now() then now() else voting_closes end,
    submission_deadline=case when voting_opens is null or voting_opens>=now() then least(coalesce(submission_deadline,now()),now()) else submission_deadline end
  where id=1;
  update submissions set locked=true;
  insert into audit_logs(actor_id,action,target_table,reason) values (auth.uid(),'competition_closed','competition_settings',p_reason);
end $$;

create function admin_set_deadline(p_ts timestamptz, p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  update competition_settings set submission_deadline=p_ts where id=1;   -- timeline CHECKs reject contradictions
  insert into audit_logs(actor_id,action,target_table,reason,details) values (auth.uid(),'deadline_changed','competition_settings',p_reason,jsonb_build_object('deadline',p_ts));
end $$;

create function admin_set_voting(p_enabled boolean, p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  update competition_settings set voting_enabled=p_enabled where id=1;
  insert into audit_logs(actor_id,action,target_table,reason) values (auth.uid(),case when p_enabled then 'voting_opened' else 'voting_closed' end,'competition_settings',p_reason);
end $$;

create function admin_publish_results(p_pub boolean, p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  update competition_settings set results_published=p_pub where id=1;
  insert into audit_logs(actor_id,action,target_table,reason) values (auth.uid(),case when p_pub then 'results_published' else 'results_hidden' end,'competition_settings',p_reason);
end $$;

create function admin_set_account(p_id uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path=public, pg_temp as $$
begin
  perform _admin_guard();
  if p_status not in ('active','suspended') or coalesce(trim(p_reason),'')='' then raise exception 'invalid'; end if;
  update profiles set account_status=p_status, suspension_reason=p_reason, updated_at=now() where id=p_id and role<>'admin';
  insert into audit_logs(actor_id,action,target_table,target_id,reason) values (auth.uid(),'account_'||p_status,'profiles',p_id::text,p_reason);
end $$;

create function admin_stats() returns jsonb language plpgsql stable security definer set search_path=public, pg_temp as $$
begin perform _admin_guard();
  return jsonb_build_object(
   'participants',(select count(*) from profiles where role='participant'),
   'approved',(select count(*) from submissions where status='approved'),
   'pending',(select count(*) from submissions where status='pending'),
   'rejected',(select count(*) from submissions where status='rejected'),
   'votes',(select count(*) from votes where status='valid'),
   'by_campus',coalesce((select jsonb_object_agg(n,c) from (select coalesce(ca.name,'—') n,count(*) c from profiles p left join campuses ca on ca.id=p.campus_id where p.role='participant' group by 1) t),'{}'));
end $$;
revoke all on function _admin_guard() from public, anon, authenticated;
revoke all on function
  admin_moderate(uuid, text, text, text),
  admin_close_competition(text),
  admin_set_deadline(timestamp with time zone, text),
  admin_set_voting(boolean, text),
  admin_publish_results(boolean, text),
  admin_set_account(uuid, text, text),
  admin_stats()
from public, anon;
grant execute on function
  admin_moderate(uuid, text, text, text),
  admin_close_competition(text),
  admin_set_deadline(timestamp with time zone, text),
  admin_set_voting(boolean, text),
  admin_publish_results(boolean, text),
  admin_set_account(uuid, text, text),
  admin_stats()
to authenticated;

-- Approved photos are viewable by anyone (via signed URLs); everything else stays private.
create function is_approved_photo(p text) returns boolean language sql stable security definer set search_path=public, pg_temp as $$
  select exists(select 1 from submissions where status='approved' and (primary_photo_path=p or secondary_photo_path=p)) $$;
create policy photos_approved_read on storage.objects for select to anon, authenticated
  using (bucket_id='submissions' and is_approved_photo(name));
