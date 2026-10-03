-- Banks above the accounts: «bank → account → card». Forward only.
--
-- Additive only, like 0004 and 0005: this file creates a table and adds a column that starts
-- empty. It changes no value an older build wrote. What needs the app — a bank for every
-- account, and the account filed under it — is the data step that runs right after this file
-- inside the same transaction (`MigrationDataSteps` in AppDatabase, rules in `BanksMigration`
-- in the core): all of it lands, or the file stays exactly as it was.
--
-- Needs SQLite 3.37 or later, as 0004 and 0005 do. Instants are UTC text, as GRDB writes them.

-- 1. Banks -------------------------------------------------------------------------------------
-- A bank owns no money: the balances, the operations and the counts stay on its accounts, as the
-- cards stay on theirs. It is what the owner names first, and what a list of choices says while
-- the bank has one account and one card. `name` is unique among the live banks — kept by the app,
-- as the names of accounts and cards are, since the archive keeps names the way every list does.
-- `sort` is the place in the lists, ahead of the name (0 everywhere is alphabetical).
CREATE TABLE banks (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL CHECK (length(trim(name)) > 0),
  sort      INTEGER NOT NULL DEFAULT 0,
  archived  INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

-- 2. The bank of an account --------------------------------------------------------------------
-- Every account the app or the update makes has one. NULL is an account a hand edit or another
-- program left without: it is read as a bank of its own name, and the app files it on the next
-- open. RESTRICT: a bank with an account under it — archived or not — is never deleted; an
-- account deleted leaves its bank where it was.
ALTER TABLE payment_methods ADD COLUMN bank_id TEXT
  REFERENCES banks(id) ON DELETE RESTRICT;
CREATE INDEX idx_payment_methods_bank ON payment_methods(bank_id)
  WHERE bank_id IS NOT NULL;
