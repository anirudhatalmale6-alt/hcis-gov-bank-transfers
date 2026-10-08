-- ============================================================================
--  Stopping one person's payment on a run
--
--  THE SCENARIO, from the Agency (8 Oct 2026)
--
--  The payroll is compiled and ready. At the last minute a care giver is
--  terminated. Somebody has to stop that one payment without disturbing the
--  other three thousand.
--
--  WHY THIS IS NOT AN ADJUSTMENT
--
--  The only tool today is "cut hours" - a quantity of hours or days withheld.
--  To stop a payment with it you would have to cut the person's whole month,
--  which makes their net pay zero, and:
--
--      ERROR: new row for relation "payment_run_transfers" violates check
--      constraint "payment_run_transfers_amount_positive"
--
--  That constraint is right - a transfer of zero is meaningless and some banks
--  reject the whole file for it. But the result is that the nine transfer
--  files fail to build FOR THE ENTIRE RUN, not just for that person, on
--  cut-off night with nobody watching. Reproduced on the live database before
--  writing this.
--
--  So stopping is a different operation from paying less:
--
--      cut hours    the person is paid, less something. Stays in the file.
--      stop         the person is NOT paid. Comes OUT of the file entirely.
--
--  WHY IT IS RECORDED RATHER THAN JUST ABSENT
--
--  The generator deliberately refuses to leave anybody out quietly, because
--  somebody silently missing from every file is simply not paid and nobody
--  finds out until they complain. A stopped payment must therefore be a
--  DECISION with a name on it - who stopped it, when, and why - so that
--  "deliberately stopped" can never be mistaken for "accidentally dropped".
--
--  WHEN IT CAN BE DONE
--
--  Up until the file goes to Finance, and not after. Once Finance hold the
--  file it is on its way to the Central Bank and nothing in HCIS can recall
--  it; that is a telephone call, not a button. Confirmed with the Agency, and
--  enforced below rather than left to good intentions.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE IF NOT EXISTS payment_run_stops (
  id             bigserial PRIMARY KEY,
  -- RESTRICT, like payment_run_transfers: the record of a decision about money
  -- must not disappear because somebody deleted a run.
  run_id         bigint NOT NULL REFERENCES payment_runs(id) ON DELETE RESTRICT,
  care_worker_id text NOT NULL,
  -- Kept as a copy, not a join. The same reasoning as payment_run_transfers:
  -- if the care giver's record is edited later, what this run did must not
  -- change underneath it.
  nin            text NOT NULL,
  care_giver_name text NOT NULL,
  -- What this payment WOULD have been. Needed so the totals still reconcile:
  -- requested = paid + withheld + stopped, and a stop with no amount leaves an
  -- unexplained hole in the month.
  amount_withheld numeric(12,2) NOT NULL CHECK (amount_withheld >= 0),
  -- NOT NULL on purpose. Six months later nobody remembers why somebody was
  -- not paid, and "no reason recorded" is exactly what makes a payroll
  -- impossible to audit.
  reason         text NOT NULL CHECK (length(btrim(reason)) > 0),
  stopped_by     text NOT NULL,
  stopped_at     timestamptz NOT NULL DEFAULT now(),
  -- A stop can be lifted before the file goes - somebody stops the wrong
  -- person, or the termination is reversed. Lifting is recorded rather than
  -- deleting the row, so the history still shows it happened.
  released_by    text,
  released_at    timestamptz,
  CONSTRAINT payment_run_stops_release_pair
    CHECK ((released_at IS NULL) = (released_by IS NULL))
);

-- One LIVE stop per person per run. A released one may sit alongside a new
-- one, which is why this is a partial index rather than a plain unique.
CREATE UNIQUE INDEX IF NOT EXISTS payment_run_stops_one_live
  ON payment_run_stops (run_id, care_worker_id)
  WHERE released_at IS NULL;

CREATE INDEX IF NOT EXISTS payment_run_stops_run_idx
  ON payment_run_stops (run_id);

-- ---------------------------------------------------------------------------
--  The deadline, enforced
--
--  Agreed with the Agency on 8 Oct: a payment can be stopped up to the moment
--  the file goes to Finance, and not afterwards. Writing that here rather than
--  only in the screen means it holds for anything that touches the database -
--  a script, a correction by hand, a future feature nobody has thought of yet.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION payment_run_stops_before_sending()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sent timestamptz; per text;
BEGIN
  SELECT sent_at, period INTO sent, per FROM payment_runs WHERE id = NEW.run_id;
  IF sent IS NOT NULL THEN
    RAISE EXCEPTION
      'The % run was sent to Finance on %. HCIS cannot stop a payment after the file has gone - that is a call to Finance.',
      per, to_char(sent, 'DD Mon YYYY HH24:MI');
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS payment_run_stops_before_sending_trg ON payment_run_stops;
CREATE TRIGGER payment_run_stops_before_sending_trg
  BEFORE INSERT OR UPDATE ON payment_run_stops
  FOR EACH ROW EXECUTE FUNCTION payment_run_stops_before_sending();

-- ---------------------------------------------------------------------------
--  Access - the post-38 pattern: signed-in HCIS staff, nothing to anon.
--  WHO may stop is decided by capability in the application; the database's
--  job here is only to keep it away from the anonymous role.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_run_stops ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF to_regprocedure('public.auth_is_hcis_staff()') IS NULL THEN
    RAISE EXCEPTION 'auth_is_hcis_staff() is missing - apply the recovery package first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE tablename = 'payment_run_stops' AND policyname = 'hcis_staff_only') THEN
    CREATE POLICY hcis_staff_only ON payment_run_stops
      FOR ALL TO authenticated
      USING (auth_is_hcis_staff()) WITH CHECK (auth_is_hcis_staff());
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT, INSERT, UPDATE ON payment_run_stops TO authenticated;
    GRANT USAGE, SELECT ON SEQUENCE payment_run_stops_id_seq TO authenticated;
  END IF;
  REVOKE ALL ON payment_run_stops FROM PUBLIC;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON payment_run_stops FROM anon;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
--  Prove the deadline actually refuses, and that it does not over-reach.
--  A guard that blocks everything is as useless as one that blocks nothing.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  unsent_run bigint; sent_run bigint; refused boolean := false; allowed boolean := false;
BEGIN
  INSERT INTO payment_runs (period) VALUES ('ZZ-STOPTEST-A') RETURNING id INTO unsent_run;
  INSERT INTO payment_runs (period, sent_at) VALUES ('ZZ-STOPTEST-B', now()) RETURNING id INTO sent_run;

  -- not yet sent -> must be allowed
  BEGIN
    INSERT INTO payment_run_stops
      (run_id, care_worker_id, nin, care_giver_name, amount_withheld, reason, stopped_by)
    VALUES (unsent_run, 'ZZ1', '000-0000-0-0-00', 'Test', 100, 'test', 'tester');
    allowed := true;
  EXCEPTION WHEN others THEN
    allowed := false;
  END;

  -- already sent -> must be refused
  BEGIN
    INSERT INTO payment_run_stops
      (run_id, care_worker_id, nin, care_giver_name, amount_withheld, reason, stopped_by)
    VALUES (sent_run, 'ZZ2', '000-0000-0-0-00', 'Test', 100, 'test', 'tester');
  EXCEPTION WHEN others THEN
    refused := true;
  END;

  DELETE FROM payment_run_stops WHERE run_id IN (unsent_run, sent_run);
  DELETE FROM payment_runs WHERE id IN (unsent_run, sent_run);

  IF NOT allowed THEN
    RAISE EXCEPTION 'The deadline guard refused a run that has NOT been sent';
  END IF;
  IF NOT refused THEN
    RAISE EXCEPTION 'The deadline guard allowed a stop on a run already sent to Finance';
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
