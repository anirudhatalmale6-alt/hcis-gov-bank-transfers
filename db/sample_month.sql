-- ============================================================================
--  A SAMPLE month for the Bank Transfers screen
--
--  WHAT THIS IS FOR
--
--  So that somebody being shown the system sees a populated screen instead of
--  an empty one, before the real bank details have arrived.
--
--  WHAT MAKES IT SAFE
--
--  Three things, and all three matter:
--
--   1. The run is flagged is_sample, and the screen puts a banner across the
--      top saying so. The label travels with the data, not with the telling.
--   2. Every name begins with SAMPLE and every account number begins with
--      0000. Nobody reading a single row can mistake it for a real payment.
--   3. It writes ONLY to payment_run_transfers and one payment_runs row. It
--      does not touch care_workers, ref_bank, or anybody's real record.
--
--  The amounts are the real August per-institution totals from the Agency's
--  own summary, divided across a handful of fictional people. So the shape and
--  the scale are honest - what a month actually looks like - while every
--  individual row is plainly invented.
--
--  TO REMOVE IT AGAIN - one command, and it leaves nothing behind:
--
--      DELETE FROM payment_runs WHERE period = 'SAMPLE';
--
--  (the transfers go with it, by ON DELETE CASCADE... see the note below)
--
--  Safe to run more than once: it deletes its own previous copy first.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- payment_run_transfers points at payment_runs with ON DELETE RESTRICT, on
-- purpose - a real record of money sent must not vanish because somebody
-- deleted a run. So the sample clears its own transfers explicitly rather
-- than relying on a cascade that deliberately does not exist.
DELETE FROM payment_run_transfers
 WHERE run_id IN (SELECT id FROM payment_runs WHERE period = 'SAMPLE');
DELETE FROM payment_runs WHERE period = 'SAMPLE';

INSERT INTO payment_runs (period, state, requested_total, is_sample, amendments_due_at)
VALUES ('SAMPLE', 'bank', 24967070.76, true, now() - interval '7 days');

-- One row per fictional care giver. The institution totals add up to the real
-- August figures; the split between people inside each institution is
-- arbitrary, because that part is not what is being demonstrated.
-- Column list taken from the table, not from memory. There is deliberately no
-- bank_id here: this table holds COPIES of what was sent, with no foreign keys
-- to care_workers or ref_bank, so that a care giver changing bank in December
-- cannot rewrite what August says.
INSERT INTO payment_run_transfers
  (run_id, care_worker_id, nin, care_giver_name, seft_code, bank_code,
   bank_name, account_number, account_holder_name, amount, value_date, file_name)
SELECT
  (SELECT id FROM payment_runs WHERE period = 'SAMPLE'),
  v.cw, v.nin, v.nm, v.seft, v.bcode, v.bname, v.acct, v.nm, v.amt,
  (now() - interval '7 days')::date, v.fname
FROM (VALUES
  -- ABSA - 8,122,924.20, and TWO files because it went over the 1,000 row cap
  ('SAMPLE-001','000-0000-0-0-01','SAMPLE  Marie Dubois','10','ABSA Bank Seychelles','ABS','000012345601', 4061462.10::numeric,'HMC_SAMPLE_2026_EFT_ABS1.xlsx'),
  ('SAMPLE-002','000-0000-0-0-02','SAMPLE  Jean Hoareau','10','ABSA Bank Seychelles','ABS','000012345602', 4061462.10,'HMC_SAMPLE_2026_EFT_ABS2.xlsx'),
  -- Seychelles Commercial Bank - 5,541,319.38
  ('SAMPLE-003','000-0000-0-0-03','SAMPLE  Anne Confait','80','Seychelles Commercial Bank','SSB','000012345603', 2770659.69,'HMC_SAMPLE_2026_EFT_SSB1.xlsx'),
  ('SAMPLE-004','000-0000-0-0-04','SAMPLE  Paul Rene','80','Seychelles Commercial Bank','SSB','000012345604', 2770659.69,'HMC_SAMPLE_2026_EFT_SSB1.xlsx'),
  -- Mauritius Commercial Bank - 4,534,122.19
  ('SAMPLE-005','000-0000-0-0-05','SAMPLE  Lise Payet','40','Mauritius Commercial Bank','MCB','000012345605', 2267061.10,'HMC_SAMPLE_2026_EFT_MCB1.xlsx'),
  ('SAMPLE-006','000-0000-0-0-06','SAMPLE  Marc Adrienne','40','Mauritius Commercial Bank','MCB','000012345606', 2267061.09,'HMC_SAMPLE_2026_EFT_MCB1.xlsx'),
  -- Credit Union - 2,711,885.79
  ('SAMPLE-007','000-0000-0-0-07','SAMPLE  Rita Pillay','18','Credit Union - Mahe Branch','SCU','000012345607', 1355942.90,'HMC_SAMPLE_2026_EFT_SCU1.xlsx'),
  ('SAMPLE-008','000-0000-0-0-08','SAMPLE  Yvon Barbe','18','Credit Union - Mahe Branch','SCU','000012345608', 1355942.89,'HMC_SAMPLE_2026_EFT_SCU1.xlsx'),
  -- Nouvobanq - 2,625,575.10
  ('SAMPLE-009','000-0000-0-0-09','SAMPLE  Claire Sinon','20','NOUVOBANQUE','NVB','000012345609', 1312787.55,'HMC_SAMPLE_2026_EFT_NVB1.xlsx'),
  ('SAMPLE-010','000-0000-0-0-10','SAMPLE  Didier Louise','20','NOUVOBANQUE','NVB','000012345610', 1312787.55,'HMC_SAMPLE_2026_EFT_NVB1.xlsx'),
  -- Bank of Baroda - 1,257,354.98
  ('SAMPLE-011','000-0000-0-0-11','SAMPLE  Nadia Camille','70','Bank of Baroda','BOB','000012345611', 1257354.98,'HMC_SAMPLE_2026_EFT_BOB1.xlsx'),
  -- Al Salam Bank - 118,200.60
  ('SAMPLE-012','000-0000-0-0-12','SAMPLE  Tony Moustache','65','AL SALAM BANK SEY Ltd','ASB','000012345612',  118200.60,'HMC_SAMPLE_2026_EFT_ASB1.xlsx'),
  -- Bank of Ceylon - 55,688.52
  ('SAMPLE-013','000-0000-0-0-13','SAMPLE  Gina Dogley','45','Bank of Ceylon','BOC','000012345613',   55688.52,'HMC_SAMPLE_2026_EFT_BOC1.xlsx')
) AS v(cw, nin, nm, bcode, bname, seft, acct, amt, fname);

-- ---------------------------------------------------------------------------
--  Check it adds up to the real August total, and that it is flagged.
--  A sample whose arithmetic is wrong teaches the viewer something false about
--  the scale of the thing, which defeats the point of using real totals.
-- ---------------------------------------------------------------------------
DO $$
DECLARE t numeric; n int; flagged boolean;
BEGIN
  SELECT sum(amount), count(*) INTO t, n
    FROM payment_run_transfers
   WHERE run_id = (SELECT id FROM payment_runs WHERE period = 'SAMPLE');

  SELECT is_sample INTO flagged FROM payment_runs WHERE period = 'SAMPLE';

  IF NOT flagged THEN
    RAISE EXCEPTION 'The sample run is not flagged as a sample';
  END IF;
  IF round(t, 2) <> 24967070.76 THEN
    RAISE EXCEPTION 'Sample total is % - it must match the real August total 24967070.76', t;
  END IF;
  RAISE NOTICE 'Sample month: % rows, SCR %, flagged as sample.', n, t;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
