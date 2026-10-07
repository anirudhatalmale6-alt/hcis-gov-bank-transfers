-- ============================================================================
--  HCIS - record what was actually sent to the banks, and every change to a
--         care giver's bank details
--
--  Two tables, and they exist for the same reason: a payment that has been
--  made is a fact about the past, and the past must not change when the
--  present does.
--
--  ---------------------------------------------------------------------------
--  WHY payment_run_transfers HOLDS COPIES AND NOT REFERENCES
--
--  The obvious way to build the accountant's screen is to join the payment run
--  to care_workers and read the bank details off there. That screen would be
--  wrong, and worse, it would be CONFIDENTLY wrong.
--
--  A care giver changes bank in December. Open August's screen afterwards and
--  it now shows the December bank - stating that August's money went to an
--  account that did not receive it. Nobody would notice, because nothing looks
--  broken. It is the same error as dating a record by when it was closed
--  rather than when it happened.
--
--  So every row here is a COPY of the values as they were at the moment the
--  file was built: the bank, the account number, the name on the account, the
--  amount, and which file the person was in. There are deliberately NO foreign
--  keys to care_workers or ref_bank for those fields. A later edit cannot
--  reach back through them, because there is nothing to reach back through.
--
--  care_worker_id is kept as a plain reference so the screen can link to the
--  person, but nothing displayed is read from there.
--
--  ---------------------------------------------------------------------------
--  WHY THE CHANGES ARE RECORDED SEPARATELY
--
--  Changing a bank account is changing where money goes. "It used to be a
--  different account" must never depend on somebody's memory. Every change is
--  written down with who made it and what it was before - including changes
--  made by a data load, not only ones typed in by a person.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
--  1. What was sent
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_run_transfers (
  id                  BIGSERIAL PRIMARY KEY,
  run_id              BIGINT      NOT NULL REFERENCES payment_runs(id) ON DELETE RESTRICT,

  -- Who. The id links to the person; the name is a copy, because people are
  -- renamed and August's file said what it said.
  care_worker_id      TEXT        NOT NULL,
  nin                 TEXT        NOT NULL,
  care_giver_name     TEXT        NOT NULL,

  -- Where the money went. All copies. See the note above.
  seft_code           TEXT        NOT NULL,
  bank_code           TEXT        NOT NULL,
  bank_name           TEXT        NOT NULL,
  account_number      TEXT        NOT NULL,
  account_holder_name TEXT        NOT NULL,

  -- How much, when, and in which file - so a bank asking "we never got this"
  -- can be answered with the file name and the value date, not a guess.
  amount              NUMERIC(14,2) NOT NULL,
  value_date          DATE        NOT NULL,
  file_name           TEXT        NOT NULL,

  generated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- An amount of zero is not a transfer, and a negative one is not something
  -- this file knows how to mean.
  CONSTRAINT payment_run_transfers_amount_positive CHECK (amount > 0),
  CONSTRAINT payment_run_transfers_account_present
    CHECK (btrim(account_number) <> '' AND btrim(seft_code) <> '')
);

-- One row per person per run. Generating twice must not double the record,
-- and two rows for one person in one month would read as two payments.
CREATE UNIQUE INDEX IF NOT EXISTS payment_run_transfers_one_per_person
  ON payment_run_transfers (run_id, nin);

CREATE INDEX IF NOT EXISTS idx_transfers_run   ON payment_run_transfers (run_id);
CREATE INDEX IF NOT EXISTS idx_transfers_whom  ON payment_run_transfers (care_worker_id);
CREATE INDEX IF NOT EXISTS idx_transfers_bank  ON payment_run_transfers (seft_code);

COMMENT ON TABLE payment_run_transfers IS
  'What was actually sent to the banks for a payroll run. Every bank/account/name field is a COPY taken when the file was built - editing a care giver later must never change what a past month says was paid.';

-- ---------------------------------------------------------------------------
--  2. Every change to where someone is paid
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS care_worker_bank_changes (
  id                      BIGSERIAL PRIMARY KEY,
  care_worker_id          TEXT        NOT NULL,
  nin                     TEXT,
  changed_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Who did it. Filled from the signed-in user where there is one; a data
  -- load has no session, and 'data load' is the honest answer rather than
  -- leaving it blank and letting somebody assume a person did it.
  changed_by              TEXT        NOT NULL DEFAULT 'unknown',

  old_bank_id             INTEGER,
  old_account_number      TEXT,
  old_account_holder_name TEXT,
  new_bank_id             INTEGER,
  new_account_number      TEXT,
  new_account_holder_name TEXT
);

CREATE INDEX IF NOT EXISTS idx_bank_changes_whom ON care_worker_bank_changes (care_worker_id);
CREATE INDEX IF NOT EXISTS idx_bank_changes_when ON care_worker_bank_changes (changed_at DESC);

COMMENT ON TABLE care_worker_bank_changes IS
  'Every change to a care giver bank details, including by data load. Changing an account changes where money goes, so what it was before must not rely on memory.';

-- The trigger writes a row only when something that affects WHERE THE MONEY
-- GOES has changed. An edit to somebody's phone number is not a bank change
-- and should not fill this table with noise.
CREATE OR REPLACE FUNCTION care_worker_bank_changed()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_who TEXT;
BEGIN
  IF NEW.bank_id             IS NOT DISTINCT FROM OLD.bank_id
     AND NEW.account_number      IS NOT DISTINCT FROM OLD.account_number
     AND NEW.account_holder_name IS NOT DISTINCT FROM OLD.account_holder_name THEN
    RETURN NEW;
  END IF;

  -- auth_uid() is the signed-in user, and it is NULL when this runs from a
  -- script or a data load. Both are legitimate; they are just not the same
  -- thing, and the record should not pretend otherwise.
  BEGIN
    v_who := coalesce(nullif(auth_uid(), ''), 'data load (no signed-in user)');
  EXCEPTION WHEN undefined_function OR insufficient_privilege THEN
    v_who := 'data load (no signed-in user)';
  END;

  INSERT INTO care_worker_bank_changes
    (care_worker_id, nin, changed_by,
     old_bank_id, old_account_number, old_account_holder_name,
     new_bank_id, new_account_number, new_account_holder_name)
  VALUES
    (NEW.display_id, NEW.nin, v_who,
     OLD.bank_id, OLD.account_number, OLD.account_holder_name,
     NEW.bank_id, NEW.account_number, NEW.account_holder_name);

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_care_worker_bank_changed ON care_workers;
CREATE TRIGGER trg_care_worker_bank_changed
  AFTER UPDATE ON care_workers
  FOR EACH ROW EXECUTE FUNCTION care_worker_bank_changed();

-- ---------------------------------------------------------------------------
--  3. Who may see this
--
--  Account numbers for ~3,800 people. Signed-in staff only - migration 38
--  already took the anonymous role's blanket access away, and these tables
--  are created after it, so they start with no grants at all. Granting
--  deliberately and by name is the point.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON payment_run_transfers     TO authenticated;
    GRANT SELECT ON care_worker_bank_changes  TO authenticated;
  END IF;
END $$;

-- Nothing is granted to anon, and this proves it rather than assuming it.
DO $$
DECLARE leaked TEXT;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    SELECT string_agg(DISTINCT table_name, ', ') INTO leaked
      FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND grantee = 'anon'
       AND table_name IN ('payment_run_transfers', 'care_worker_bank_changes');
    IF leaked IS NOT NULL THEN
      RAISE EXCEPTION 'These hold account numbers and are readable without signing in: %', leaked;
    END IF;
  END IF;
END $$;

COMMIT;

\echo ''
\echo '  ---------------------------------------------------------'
\echo '  WHAT IS RECORDED'
\echo '  ---------------------------------------------------------'

SELECT (SELECT count(*) FROM payment_run_transfers)    AS "transfers recorded",
       (SELECT count(*) FROM care_worker_bank_changes) AS "bank changes recorded";

NOTIFY pgrst, 'reload schema';
