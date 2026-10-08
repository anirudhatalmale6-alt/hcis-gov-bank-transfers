-- ============================================================================
--  A payroll run can declare itself a SAMPLE
--
--  WHY THIS EXISTS
--
--  Before the real bank details arrive, the Bank Transfers screen is empty on
--  every machine - correctly, because no transfer files have ever been built.
--  An empty screen shown to people being asked to approve the system reads as
--  "it does not work", and the honest explanation ("the data has not arrived")
--  is not something they can see.
--
--  So there has to be a way to demonstrate a populated screen. The dangerous
--  way is to quietly insert plausible rows and let the screen look real. That
--  leaves a document inside a government payroll system saying money went to
--  named accounts - and whoever reads it in six months was not in the room and
--  has no way to know it was a demonstration.
--
--  This is the safe way: the run itself carries a flag, and the screen refuses
--  to show a sample run without saying so. The label travels WITH the data, so
--  it survives a screenshot, a forwarded e-mail, and somebody opening the page
--  a year later with no context.
--
--  NOT A DISPLAY SETTING. It is a column on the run, not a preference in the
--  UI, precisely so it cannot be switched off while the data stays.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

ALTER TABLE payment_runs
  ADD COLUMN IF NOT EXISTS is_sample boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN payment_runs.is_sample IS
  'True for demonstration data. The Bank Transfers screen shows a banner and '
  'refuses to present it as a record of real payments. Never set this on a run '
  'that represents money actually sent.';

-- The cut-off job must never e-mail a sample to Finance. It selects runs whose
-- cut-off has passed and which have not been sent; a sample sitting in the
-- table would qualify. This makes that impossible at the database rather than
-- relying on the job remembering to ask.
CREATE OR REPLACE FUNCTION payment_runs_sample_never_sent()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_sample AND NEW.sent_at IS NOT NULL THEN
    RAISE EXCEPTION
      'Run % is marked as sample data and cannot be recorded as sent to Finance',
      NEW.period;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS payment_runs_sample_never_sent_trg ON payment_runs;
CREATE TRIGGER payment_runs_sample_never_sent_trg
  BEFORE INSERT OR UPDATE ON payment_runs
  FOR EACH ROW EXECUTE FUNCTION payment_runs_sample_never_sent();

-- ---------------------------------------------------------------------------
--  Prove the guard actually refuses, rather than trusting that it is there.
-- ---------------------------------------------------------------------------
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    INSERT INTO payment_runs (period, is_sample, sent_at)
    VALUES ('9999-01', true, now());
  EXCEPTION WHEN others THEN
    refused := true;
  END;

  IF NOT refused THEN
    DELETE FROM payment_runs WHERE period = '9999-01';
    RAISE EXCEPTION 'The sample guard did not refuse a sample marked as sent';
  END IF;

  -- And the other direction: a normal run must still be allowed to be sent,
  -- or this guard has broken the thing it was meant to protect.
  INSERT INTO payment_runs (period, is_sample, sent_at)
  VALUES ('9999-02', false, now());
  DELETE FROM payment_runs WHERE period = '9999-02';
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
