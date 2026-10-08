-- ============================================================================
--  HCIS - the monthly payroll runs
--
--  WHY THIS FILE EXISTS, AND WHY IT IS NUMBERED 42b
--
--  INSTALL.bat stopped on the government box on 8 October with:
--
--      STOPPING. Nothing has been changed.
--      This database is missing things these changes build on:
--        payment_runs - the monthly payroll runs
--
--  It was right to stop. The payroll-runs feature was built on the office
--  server in September and was never part of the recovery package (30-42), so
--  the government box has never had it. Changes 43-46 all build on top of it:
--  43 hangs bank details off a care giver, 45 records what was sent against a
--  RUN, and a foreign key needs something to point at.
--
--  It is 42b rather than 47 because it belongs BEFORE 43, not after. Numbering
--  it 47 would have it applied last, and 45 would fail.
--
--  WHERE THE SHAPE CAME FROM - NOT FROM THE SEPTEMBER FILE
--
--  There is a file in the repository, 2026-09-05_payment_runs.sql, that creates
--  these tables. I did NOT copy it, and it must not be used here, for two
--  reasons found by asking the office database what it actually looks like
--  today rather than trusting the file:
--
--  1. IT IS MISSING TWO COLUMNS. The office table has sent_at and sent_to;
--     the September file has neither. They were added when the cut-off e-mail
--     job was built. That job reads sent_at on every run - it is how it knows
--     not to send the same month twice:
--
--         SELECT id, state, withholding_rule, amendments_due_at,
--                downloaded_at, sent_at FROM payment_runs WHERE period = ...
--
--     Install the September file and INSTALL.bat passes, the screens work, and
--     then the payroll job fails at the end of the month with "column sent_at
--     does not exist" - on the one night of the month nobody is watching.
--
--  2. ITS GRANTS WOULD RE-OPEN THE HOLE CHANGE 38 CLOSED. It says
--
--         CREATE POLICY payment_runs_all ON payment_runs
--           FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
--         GRANT ALL ON payment_runs, payment_run_adjustments TO anon, ...
--
--     i.e. the ANONYMOUS role gets full read and write on the payroll. That is
--     exactly what 38_remove_the_default_grants.sql exists to prevent, after a
--     view leaked names and identity numbers to unauthenticated HTTP in
--     September. The office box no longer looks like that either - its policy
--     is hcis_staff_only, authenticated only. The file is simply stale.
--
--  So this reproduces the office database AS IT IS, which is the thing the
--  payroll code is actually written against.
--
--  SAFE TO RUN MORE THAN ONCE. Every statement is IF NOT EXISTS or guarded.
--  Nothing is dropped and no existing row is touched, so running it on a box
--  that already has these tables changes nothing.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
--  The run
--
--  Final approval already exists on each individual payment. What has never
--  existed is the RUN: the CEO does not approve payments one at a time, he
--  requests a sum - process 2,000,000 this month - and Finance release against
--  it. Without a run there is nowhere to record that figure, so there is no
--  ceiling to check a total against and no variance to explain afterwards.
--
--  The chain, as Finance's IT department described it:
--
--    HCIS  ->  Finance Department  ->  Central Bank  ->  each carer's own bank
--
--  HCIS's part ends when the run is released to Finance, so 'bank' below means
--  "sent to the Central Bank" - the last thing HCIS can honestly know about.
--
--  Column order matches the office box exactly, including downloaded_at,
--  sent_at and sent_to at the end where they were added later.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_runs (
  id                bigserial PRIMARY KEY,
  period            text NOT NULL UNIQUE,            -- 'YYYY-MM'
  state             text NOT NULL DEFAULT 'hc'
                    CHECK (state IN ('hc','requested','ack','verified','bank')),
  -- The sum the CEO requested. A CEILING: paying under it is inside the
  -- authority already given; paying over it is a new request.
  requested_total   numeric(14,2) NOT NULL DEFAULT 0,
  withholding_rule  text NOT NULL DEFAULT 'hours'
                    CHECK (withholding_rule IN ('hours','days')),
  requested_by      text,
  requested_at      timestamptz,
  -- A SCHEDULE, not a permission. What decides whether a line may still change
  -- is `state`. A deadline going by is not an approval, and silence is never
  -- read as one.
  amendments_due_at timestamptz,
  -- HC saying out loud that they have finished. Any later amendment sets this
  -- back to false.
  hc_final          boolean NOT NULL DEFAULT false,
  acknowledged_by   text,
  acknowledged_at   timestamptz,
  verified_by       text,
  verified_at       timestamptz,
  banked_by         text,
  banked_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- When Finance took their copy. THIS is the lock, not the bank push: from
  -- the moment somebody else holds the file, changing ours leaves the two
  -- disagreeing with nothing to say which is right.
  downloaded_at     timestamptz,
  -- The cut-off job stamps these. sent_at is what stops the same month being
  -- e-mailed twice, so it is not optional decoration.
  sent_at           timestamptz,
  sent_to           text
);

-- If an older version of this table is already here - one built from the
-- September file - add what it is missing rather than failing. This is the
-- case that bites silently, so it is handled explicitly.
ALTER TABLE payment_runs ADD COLUMN IF NOT EXISTS downloaded_at timestamptz;
ALTER TABLE payment_runs ADD COLUMN IF NOT EXISTS sent_at       timestamptz;
ALTER TABLE payment_runs ADD COLUMN IF NOT EXISTS sent_to       text;

-- ---------------------------------------------------------------------------
--  Adjustments
--
--  One row per correction, against the care giver's EXISTING line. It never
--  adds a second payment line, and that is not a style preference: Finance pay
--  once per identity number, so a correction row would be read as a duplicate
--  and thrown away. The correction would vanish and the file would look fine.
--
--  The reason is NOT NULL on purpose. Six months later nobody remembers why a
--  figure moved, and a deduction with no reason attached is exactly what makes
--  the present spreadsheet impossible to check.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_run_adjustments (
  id             bigserial PRIMARY KEY,
  run_id         bigint NOT NULL REFERENCES payment_runs(id) ON DELETE CASCADE,
  care_worker_id text NOT NULL,
  amount         numeric(10,2) NOT NULL CHECK (amount > 0),
  reason         text NOT NULL CHECK (length(btrim(reason)) > 0),
  -- Made after amendments_due_at. Still allowed - the state decides that, not
  -- the clock - but recorded, because Finance may already be looking at the
  -- figures and deserve to know one moved late.
  late           boolean NOT NULL DEFAULT false,
  created_by     text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payment_run_adjustments_run_idx
  ON payment_run_adjustments (run_id);

-- ---------------------------------------------------------------------------
--  Access - signed-in HCIS staff, and nobody else
--
--  This is the post-38 pattern, and it is what the office box actually has:
--  policy hcis_staff_only, gated on auth_is_hcis_staff(), granted to
--  `authenticated` only. The anonymous role is given nothing at all, and that
--  is asserted below rather than assumed.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_runs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_run_adjustments ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  -- auth_is_hcis_staff() comes from 30_nars_and_access_control.sql. If it is
  -- not here, the recovery package has not been applied and stopping now is
  -- far better than creating a table whose policy cannot be evaluated.
  IF to_regprocedure('public.auth_is_hcis_staff()') IS NULL THEN
    RAISE EXCEPTION
      'auth_is_hcis_staff() is missing - apply the recovery package (30-42) first';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE tablename = 'payment_runs'
                    AND policyname = 'hcis_staff_only') THEN
    CREATE POLICY hcis_staff_only ON payment_runs
      FOR ALL TO authenticated
      USING (auth_is_hcis_staff()) WITH CHECK (auth_is_hcis_staff());
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE tablename = 'payment_run_adjustments'
                    AND policyname = 'hcis_staff_only') THEN
    CREATE POLICY hcis_staff_only ON payment_run_adjustments
      FOR ALL TO authenticated
      USING (auth_is_hcis_staff()) WITH CHECK (auth_is_hcis_staff());
  END IF;

  -- A policy left over from the September file would be permissive and open to
  -- anon. Remove it if it is here; leaving it would silently override the one
  -- above, because policies are OR-ed together.
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE tablename = 'payment_runs' AND policyname = 'payment_runs_all') THEN
    DROP POLICY payment_runs_all ON payment_runs;
    RAISE NOTICE 'Removed the old open policy payment_runs_all.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE tablename = 'payment_run_adjustments'
                AND policyname = 'payment_run_adjustments_all') THEN
    DROP POLICY payment_run_adjustments_all ON payment_run_adjustments;
    RAISE NOTICE 'Removed the old open policy payment_run_adjustments_all.';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE
      ON payment_runs, payment_run_adjustments TO authenticated;
    GRANT USAGE, SELECT ON SEQUENCE payment_runs_id_seq            TO authenticated;
    GRANT USAGE, SELECT ON SEQUENCE payment_run_adjustments_id_seq TO authenticated;
  END IF;

  -- Belt and braces. 38 stopped new tables being born public, but if this file
  -- is ever applied to a box where that has not run, this takes it back.
  --
  -- PUBLIC as well as anon, and that is not tidiness. A grant to PUBLIC is a
  -- grant to every role including anon, and REVOKE ... FROM anon does not
  -- touch it - the privilege is not held by anon, it is inherited. Revoking
  -- only the named role leaves the table readable and the revoke looks like it
  -- worked.
  REVOKE ALL ON payment_runs, payment_run_adjustments FROM PUBLIC;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON payment_runs, payment_run_adjustments FROM anon;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
--  Prove it, rather than assume it
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  missing TEXT;
  leaked  TEXT;
BEGIN
  -- Every column the payroll and cut-off code reads must exist. Named one by
  -- one so the error says WHICH, not just "something is wrong".
  SELECT string_agg(c, ', ') INTO missing
    FROM unnest(ARRAY['id','period','state','requested_total','withholding_rule',
                      'amendments_due_at','hc_final','downloaded_at',
                      'sent_at','sent_to']) AS c
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public'
                        AND table_name = 'payment_runs'
                        AND column_name = c);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'payment_runs is still missing: %', missing;
  END IF;

  -- Asked with has_table_privilege, NOT by looking for the anonymous role in
  -- the grants table.
  --
  -- The grants table lists who a privilege was GRANTED to. It does not answer
  -- who can USE it. A grant to PUBLIC appears under PUBLIC, and a privilege
  -- picked up through role membership appears under the other role - in both
  -- cases anon can read the payroll and a search for grantee = 'anon' finds
  -- nothing and reports all clear.
  --
  -- has_table_privilege answers the question actually being asked: can this
  -- role, by any route, read this table. The first version of this check got
  -- it wrong, and the wrong version cannot fail - which is the worst kind.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    SELECT string_agg(t, ', ') INTO leaked
      FROM unnest(ARRAY['public.payment_runs','public.payment_run_adjustments']) AS t
     WHERE has_table_privilege('anon', t, 'SELECT')
        OR has_table_privilege('anon', t, 'INSERT')
        OR has_table_privilege('anon', t, 'UPDATE')
        OR has_table_privilege('anon', t, 'DELETE');
    IF leaked IS NOT NULL THEN
      RAISE EXCEPTION 'Reachable without signing in: %', leaked;
    END IF;
  END IF;
END $$;

COMMIT;

-- Let the API see the new tables.
NOTIFY pgrst, 'reload schema';
