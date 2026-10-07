-- ============================================================================
--  HCIS - where a care giver's money actually goes
--
--  The Agency accountant produces nine bank transfer files every month, by
--  hand, from data HCIS does not hold. HCIS knows what each care giver is
--  owed; it does not know which bank or which account to send it to.
--
--  This adds the four things that are missing. It adds no rows and changes no
--  existing value - every column is nullable, so the system behaves exactly as
--  it does today until something fills them in.
--
--  ---------------------------------------------------------------------------
--  WHY FOUR COLUMNS AND NOT TWO
--
--  bank_id            Points at ref_bank, which already holds all 25 banks
--                     with the accountant's own codes (10 ABSA, 18 Credit
--                     Union Mahe, 25 TREASURY...). A text bank name here
--                     would be a second list to keep in step with the first,
--                     and the day they disagree the transfer file is wrong.
--
--  bank_branch_code   The transfer files are grouped by INSTITUTION, one file
--                     each, but each row carries its own branch - Seychelles
--                     Commercial has six branches in a single file. So the
--                     branch has to be recorded per person, not derived from
--                     the bank.
--
--  account_number     Kept as TEXT, deliberately. Account numbers are not
--                     arithmetic: they can carry leading zeros, and a number
--                     type would silently eat them. "0041" becoming "41" is
--                     a transfer to nobody.
--
--  account_holder_name
--                     NOT the same as the care giver's name, and this is the
--                     one that would have been missed. The accountant's master
--                     list has them as separate columns because they differ -
--                     an account in a relative's name, a maiden name, a joint
--                     account. The bank matches on what is written here, not
--                     on who the payment is for.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

ALTER TABLE care_workers
  ADD COLUMN IF NOT EXISTS bank_id             INTEGER,
  ADD COLUMN IF NOT EXISTS bank_branch_code    TEXT,
  ADD COLUMN IF NOT EXISTS account_number      TEXT,
  ADD COLUMN IF NOT EXISTS account_holder_name TEXT;

-- The foreign key is added separately and only if it is not already there.
-- ADD CONSTRAINT has no IF NOT EXISTS, so a second run would fail on it.
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'care_workers_bank_id_fkey'
           AND conrelid = 'public.care_workers'::regclass) THEN
    ALTER TABLE care_workers
      ADD CONSTRAINT care_workers_bank_id_fkey
      FOREIGN KEY (bank_id) REFERENCES ref_bank(bankid);
    RAISE NOTICE 'bank_id now has to be one of the banks in ref_bank.';
  END IF;
END $$;

-- An account number with no bank is not payable, and a bank with no account
-- number is not payable either. Either both or neither - a half-filled row
-- would pass every check and then fail at the bank, which is the expensive
-- place to find out.
--
-- Written to allow NULL/NULL, because that is every row today.
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'care_workers_bank_pair'
           AND conrelid = 'public.care_workers'::regclass) THEN
    ALTER TABLE care_workers
      ADD CONSTRAINT care_workers_bank_pair
      CHECK (
        (bank_id IS NULL     AND btrim(coalesce(account_number, '')) = '')
        OR
        (bank_id IS NOT NULL AND btrim(coalesce(account_number, '')) <> '')
      );
    RAISE NOTICE 'A care giver now has either both a bank and an account, or neither.';
  END IF;
END $$;

-- Finding everyone at one bank is the whole job once a month, so it is worth
-- an index rather than reading 11,771 rows nine times.
CREATE INDEX IF NOT EXISTS idx_care_workers_bank ON care_workers (bank_id);

COMMENT ON COLUMN care_workers.bank_id IS
  'Which bank, from ref_bank. NULL means no bank details recorded yet.';
COMMENT ON COLUMN care_workers.bank_branch_code IS
  'Branch code as the accountant writes it (80, 82, 40...). Several branches share one transfer file.';
COMMENT ON COLUMN care_workers.account_number IS
  'Text, not a number - leading zeros are part of the account number.';
COMMENT ON COLUMN care_workers.account_holder_name IS
  'Whose name the account is in. May differ from the care giver - the bank matches on this.';

COMMIT;

-- ---------------------------------------------------------------------------
--  What is there now
-- ---------------------------------------------------------------------------
\echo ''
\echo '  ---------------------------------------------------------'
\echo '  CARE GIVERS AND THEIR BANK DETAILS'
\echo '  ---------------------------------------------------------'

SELECT count(*)                                        AS "care givers",
       count(*) FILTER (WHERE status = 'active')        AS "of those, active",
       count(bank_id)                                   AS "with a bank recorded",
       count(*) FILTER (WHERE status = 'active' AND bank_id IS NULL)
                                                        AS "active, still missing"
  FROM care_workers;

\echo ''
\echo '  The 25 banks are already here with the accountants own codes:'

SELECT bankcode AS code, bankname AS bank
  FROM ref_bank
 ORDER BY lpad(bankcode, 3, '0')
 LIMIT 8;

NOTIFY pgrst, 'reload schema';
