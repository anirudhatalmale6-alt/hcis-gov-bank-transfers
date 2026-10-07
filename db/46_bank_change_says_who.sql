-- ============================================================================
--  HCIS - the bank change history should name a person, not a UUID
--
--  Migration 45 recorded changed_by as whatever auth_uid() returned, which is
--  the signed-in user's internal id:
--
--      a231c2dd-0519-4815-9c21-a862249ccfe7 | none -> 00499999
--
--  That is a correct record and a useless one. The whole point of the history
--  is that somebody can look at it and see who moved an account. Nobody knows
--  that id, and looking it up means a second query against a table the reader
--  may not be able to see.
--
--  So the username is resolved AT THE TIME OF THE CHANGE and stored as text.
--  Not joined when the screen is drawn - stored. An account can be renamed or
--  deleted, and "who changed this" must survive that: it is a record of what
--  happened, exactly like the transfer rows next to it.
--
--  The id is kept alongside, because the name is for reading and the id is for
--  being certain.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

ALTER TABLE care_worker_bank_changes
  ADD COLUMN IF NOT EXISTS changed_by_id TEXT;

COMMENT ON COLUMN care_worker_bank_changes.changed_by IS
  'Username as it was when the change was made. Text, not a reference - renaming or deleting the account must not erase who did this.';
COMMENT ON COLUMN care_worker_bank_changes.changed_by_id IS
  'The internal id of that account, for certainty. changed_by is the one to read.';

CREATE OR REPLACE FUNCTION care_worker_bank_changed()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid  TEXT;
  v_who  TEXT;
BEGIN
  IF NEW.bank_id             IS NOT DISTINCT FROM OLD.bank_id
     AND NEW.account_number      IS NOT DISTINCT FROM OLD.account_number
     AND NEW.account_holder_name IS NOT DISTINCT FROM OLD.account_holder_name THEN
    RETURN NEW;
  END IF;

  -- auth_uid() is NULL when this runs from a script or a data load. Both are
  -- legitimate; they are just not a person, and the record should not imply
  -- one.
  BEGIN
    v_uid := nullif(auth_uid(), '');
  EXCEPTION WHEN undefined_function OR insufficient_privilege THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    v_who := 'data load (no signed-in user)';
  ELSE
    SELECT username INTO v_who FROM system_users WHERE id::text = v_uid;
    -- A signed-in id that matches no account should not be silently dropped.
    -- Saying so is better than an empty column nobody can explain later.
    v_who := coalesce(v_who, 'unknown account ' || v_uid);
  END IF;

  INSERT INTO care_worker_bank_changes
    (care_worker_id, nin, changed_by, changed_by_id,
     old_bank_id, old_account_number, old_account_holder_name,
     new_bank_id, new_account_number, new_account_holder_name)
  VALUES
    (NEW.display_id, NEW.nin, v_who, v_uid,
     OLD.bank_id, OLD.account_number, OLD.account_holder_name,
     NEW.bank_id, NEW.account_number, NEW.account_holder_name);

  RETURN NEW;
END $$;

-- Rows already written hold an id in changed_by. Fill in the name where the
-- account still exists, and move the id to where it belongs. Only rows that
-- look like a bare UUID are touched - 'data load (no signed-in user)' is
-- already the right answer and must not be rewritten.
UPDATE care_worker_bank_changes c
   SET changed_by_id = c.changed_by,
       changed_by    = coalesce(u.username, 'unknown account ' || c.changed_by)
  FROM (SELECT id, username FROM system_users) u
 WHERE c.changed_by ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   AND u.id::text = c.changed_by;

COMMIT;

\echo ''
\echo '  ---------------------------------------------------------'
\echo '  WHO HAS CHANGED BANK DETAILS'
\echo '  ---------------------------------------------------------'

SELECT changed_by AS "changed by", count(*) AS changes
  FROM care_worker_bank_changes
 GROUP BY changed_by ORDER BY count(*) DESC;

NOTIFY pgrst, 'reload schema';
