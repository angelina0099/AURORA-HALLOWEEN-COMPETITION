-- Limit gallery browsing and approved-photo access to signed-in participants.
revoke all on public.public_gallery from public, anon;
grant select on public.public_gallery to authenticated;

drop policy if exists photos_approved_read on storage.objects;
create policy photos_approved_read on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and is_approved_photo(name));

revoke all on function is_approved_photo(text) from public, anon;
grant execute on function is_approved_photo(text) to authenticated;
