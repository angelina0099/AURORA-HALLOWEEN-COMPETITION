update competition_settings
set submission_deadline = '2026-10-31 23:59:59+00',
    voting_enabled = true,
    voting_opens = '2026-11-01 00:00:00+00',
    voting_closes = '2026-11-02 00:00:00+00'
where id = 1;
