# AURORA Halloween Makeup Competition

## Status
Done: database schema, RLS, atomic voting function, storage policies (`supabase/migrations/0001_aurora_core.sql`).
To build next: Next.js UI (pages in the spec), Zod-validated server actions, rate limiting, admin dashboard, tests.

## Setup
1. Create a Supabase project. Auth → enable Email provider with "Confirm email" ON; set Site URL and redirect URLs.
2. In the Supabase SQL Editor, run the files in `supabase/migrations/` in numeric order (`0001` through `0005`), or run `supabase db push`.
3. Copy `.env.example` to `.env.local` and fill the values. Keep the service-role key server-side only.
4. Campus names are typed during registration. Existing campus records remain available; matching typed names are linked automatically.
5. Migration `0004_competition_schedule.sql` sets the 2026 schedule: submissions close October 31, voting opens November 1 and closes at the start of November 2, and results are announced November 2.

## First administrator (no credentials in code)
Register normally and verify your email, then in the SQL Editor (service role only):
`update profiles set role='admin' where normalized_email='you@example.com';`
Clients cannot change `role`: column grants block it and the signup trigger always creates participants.

## How rules are enforced
- One account: unique `normalized_email` / `normalized_phone`. Duplicate suspects get admin review, not auto-bans.
- One entry: `submissions.participant_id` unique. Max two photos: only two path columns exist.
- One vote: `votes.voter_id` unique. Votes can only be written through `cast_vote()`, and direct insert is revoked.
- No self-vote: checked in `cast_vote()` and again by a trigger on `votes`. Attempts are logged to `audit_logs`.
- Hidden results: `get_results()` returns rows only if `results_published` is true or the caller is an admin.

## Tests to write (Vitest + Supabase local)
Duplicate email, role escalation attempt, second submission, self-vote, double vote, vote while closed,
vote for a pending entry, 20 concurrent `cast_vote` calls producing 1 row, participant calling admin APIs, results hidden until published.

## Front end (`web/index.html`)
The static site is built for Vercel from `web/` into `dist/`. Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` as Vercel project environment variables; the build embeds these public client settings in the generated site. The anon key is intended for browser use and must be protected by the database's RLS policies. Never expose the service-role key.
For local builds, set those two variables in your shell and run `npm run build`. The generated `dist/` folder is ignored by Git.

## Deploy with GitHub and Vercel
Import the GitHub repository into Vercel with the repository root as the project root. Vercel uses `npm run build` and publishes `dist/` as configured in `vercel.json`. Add `NEXT_PUBLIC_SUPABASE_URL` (`https://<project-ref>.supabase.co`) and `NEXT_PUBLIC_SUPABASE_ANON_KEY` (the project's publishable/anon key) to the Vercel project's environment variables, then deploy. Afterward, add the deployed site URL to Supabase Auth's Site URL and redirect URLs. Do not add a service-role key to this static frontend.
Run the migrations in numeric order before using the site. In Supabase Auth settings add your site URL to the redirect URLs.
Admin controls: Close competition now (reason required, voting stops, entries locked), change submission deadline, open/close voting, publish/hide results, approve/reject, suspend/reactivate. All are audited.

## Migration 0003, schedule, and tests
Migration `0003_integrity_tools.sql` adds vote invalidation (reason required, audited), vote inspection, suspected-duplicate review, and vote summary export. Migration `0005_typed_campus_names.sql` enables free-text campus entry and updates related public/admin views and reports.
Note: an invalidated vote still uses that voter's one vote.
Tests: `psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/aurora_rules.sql` on a local/test database (rolls back; prints PASS/FAIL per rule).
Concurrency check: run `select cast_vote('<entry-id>')` from 20 parallel sessions with the same user (e.g. pgbench); the unique constraint on `votes.voter_id` guarantees one row.
Photos are resized to max 1600px WebP in the browser before upload; corrupted files are rejected.
