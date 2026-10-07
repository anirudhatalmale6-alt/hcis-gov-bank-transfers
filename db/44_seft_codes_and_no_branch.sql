-- ============================================================================
--  HCIS - what the banks are called IN THE TRANSFER FILE, and one column
--         removed that should never have been added
--
--  Written after reading all nine of the August transfer files - 3,795 rows,
--  every one of them, not a sample. Two things came out of that.
--
--  ---------------------------------------------------------------------------
--  1. ReceiverBranch IS NEVER USED. REMOVING bank_branch_code.
--
--  I added that column yesterday on the reasoning that transfer files are
--  grouped by institution while branches sit inside them - Seychelles
--  Commercial has six branches in one file - so the branch must travel with
--  the person.
--
--  It does not. ReceiverBranch is EMPTY in all 3,795 rows of all nine files.
--  So is ReceiverSEFTID. The banks do not want them.
--
--  The column is dropped rather than left sitting there empty. It was added
--  yesterday, nothing has ever been written to it, and a column that exists
--  but is never filled is an invitation for somebody to spend a week
--  collecting 3,834 branch codes that no file will ever carry.
--
--  ---------------------------------------------------------------------------
--  2. THE TRANSFER FILE CALLS THE BANKS SOMETHING ELSE.
--
--  ref_bank holds the accountant's numeric codes - 10, 18, 40, 80. The
--  transfer file uses a three-letter institution code: ABS, SCU, MCB, SSB.
--  They are not the same list and they are not one-to-one:
--
--      10 ABSA Bank Seychelles   -+
--      50 ABSA Bank Providence   -+-> ABS
--
--      80, 82, 83, 85, 90, 91 Seychelles Commercial -> SSB   (six to one)
--
--  So the mapping has to be recorded. It goes on ref_bank, one value per row,
--  because that is where the rest of the bank reference data already lives -
--  a second list somewhere else would be a second thing to keep in step.
--
--  ---------------------------------------------------------------------------
--  FOUR BANKS ARE DELIBERATELY LEFT EMPTY
--
--  TREASURY, Development Bank, Central Bank and SBM had nobody being paid
--  through them in August, so no file exists and I have not seen what the
--  banks call them. I am not inventing four codes that look plausible.
--
--  NULL here is the honest answer, and the generator must REFUSE to build a
--  file when somebody is at one of them - by name, loudly. The alternative is
--  a care giver quietly missing from every file and not being paid, which
--  nobody would notice until they complained.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---- 1. the column that is not needed --------------------------------------
DO $$
DECLARE v_n BIGINT;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'care_workers'
                AND column_name = 'bank_branch_code') THEN

    -- Never drop a column that somebody has put data in, even one I added
    -- myself yesterday. If anything is in there, stop and let a person decide.
    EXECUTE 'SELECT count(*) FROM care_workers WHERE btrim(coalesce(bank_branch_code, '''')) <> ''''' INTO v_n;
    IF v_n > 0 THEN
      RAISE EXCEPTION
        'bank_branch_code holds % non-empty values, so I am not dropping it. Somebody has started using it - tell me before this runs again.', v_n;
    END IF;

    ALTER TABLE care_workers DROP COLUMN bank_branch_code;
    RAISE NOTICE 'bank_branch_code removed - the transfer files never carry a branch.';
  END IF;
END $$;

-- ---- 2. the three-letter code the transfer file uses -----------------------
ALTER TABLE ref_bank
  ADD COLUMN IF NOT EXISTS seft_code TEXT;

COMMENT ON COLUMN ref_bank.seft_code IS
  'What the bank transfer file calls this institution (ABS, SCU, MCB...). Several branches share one. NULL means not yet known - the transfer file generator refuses rather than guessing.';

-- Taken from the August files: the ReceiverBank value in each, matched to the
-- institution by name. Written as a lookup rather than a long CASE so that
-- adding one later is a line, not a rewrite.
WITH m(code, seft) AS (VALUES
    ('10', 'ABS'),   -- ABSA Bank Seychelles
    ('50', 'ABS'),   -- ABSA Bank Providence
    ('18', 'SCU'),   -- Credit Union - Mahe
    ('19', 'SCU'),   -- Credit Union - Praslin
    ('20', 'NVB'),   -- NOUVOBANQUE
    ('21', 'NVB'),   -- NOUVOBANQUE Baie St. Anne
    ('22', 'NVB'),   -- NOUVOBANQUE La Digue
    ('40', 'MCB'),   -- Mauritius Commercial Bank
    ('41', 'MCB'),   -- M.C.B Cote D'or
    ('42', 'MCB'),   -- M.C.B. La Digue
    ('43', 'MCB'),   -- M.C.B. Anse Royale
    ('44', 'MCB'),   -- M.C.B. Grand Anse Praslin
    ('45', 'BOC'),   -- Bank of Ceylon
    ('65', 'ASB'),   -- Al Salam Bank
    ('70', 'BOB'),   -- Bank of Baroda
    ('80', 'SSB'),   -- Seychelles Commercial Bank
    ('82', 'SSB'),   -- Seychelles Commercial Bank Providence
    ('83', 'SSB'),   -- Seychelles Commercial Bank La Digue
    ('85', 'SSB'),   -- Seychelles Commercial Bank Anse Aux Pins
    ('90', 'SSB'),   -- Seychelles Commercial Bank Baie Ste Anne
    ('91', 'SSB')    -- Seychelles Commercial Bank Grand Anse
)
UPDATE ref_bank b SET seft_code = m.seft
  FROM m WHERE b.bankcode = m.code
    AND b.seft_code IS DISTINCT FROM m.seft;

-- Every code written here must be one the banks actually use. A typo would
-- produce a file named after a bank that does not exist.
DO $$
DECLARE bad TEXT;
BEGIN
  SELECT string_agg(DISTINCT seft_code, ', ') INTO bad
    FROM ref_bank
   WHERE seft_code IS NOT NULL
     AND seft_code NOT IN ('ABS','ASB','BOB','BOC','MCB','NVB','SCU','SSB');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'These are not codes seen in any transfer file: %', bad;
  END IF;
END $$;

COMMIT;

\echo ''
\echo '  ---------------------------------------------------------'
\echo '  HOW THE TRANSFER FILE WILL NAME EACH BANK'
\echo '  ---------------------------------------------------------'

SELECT coalesce(seft_code, '(not known)')          AS "in the file",
       count(*)                                     AS "bank codes",
       string_agg(bankcode, ', ' ORDER BY lpad(bankcode, 3, '0')) AS "which ones"
  FROM ref_bank
 GROUP BY seft_code
 ORDER BY seft_code NULLS LAST;

\echo ''
\echo '  These four have no code because nobody was paid through them in'
\echo '  August. The generator refuses rather than guessing:'

SELECT bankcode AS code, bankname AS bank
  FROM ref_bank
 WHERE seft_code IS NULL
 ORDER BY lpad(bankcode, 3, '0');

NOTIFY pgrst, 'reload schema';
