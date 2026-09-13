import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../../patches/server-url/YNABServerURLBridge.m', import.meta.url), 'utf8');
assert.match(source, /ynabCreateOfflineAccount/);
assert.match(source, /ynabValidateOfflineAccount/);
assert.match(source, /ynabReadOfflinePairingCategories/);
assert.match(source, /ynabLocalPairingCategories\(budgetId\)/);
assert.match(source, /mobileTransactionManagerExecuteWithState:action:completionHandler:/);
assert.match(source, /accountOperationKey/);
assert.match(source, /isSameOfflineDocumentURL\(view\.URL, expected\)/);
assert.match(source, /isSameOfflineDocumentURL\(current\.URL, expected\)/);
assert.match(source, /if \(!url\.isFileURL\) return NO/);
assert.doesNotMatch(source, /return YNABOfflineDocumentForURL\(url\) != nil/);
assert.doesNotMatch(source, /URLByStandardizingPath isEqual:expected\.URLByStandardizingPath/);
assert.match(source, /ynabLocalAccount\(accountId, budgetId\)/);
assert.match(source, /saved \? readback/);
const savedRefreshBlock = source.match(/if \(saved\) \{([\s\S]*?)\n\s*\}/)?.[1];
assert.ok(savedRefreshBlock, 'durable account readback must guard post-save refresh');
assert.match(savedRefreshBlock, /objc_setAssociatedObject\((?:fresh|current), &accountCreatedKey, \@YES/);
const readbackBranch = source.slice(source.indexOf('BOOL saved ='), source.indexOf('sendOfflineAccountResult(current, requestId, saved'));
assert.doesNotMatch(readbackBranch.slice(0, readbackBranch.indexOf('if (saved)')), /accountCreatedKey/,
  'missing readback must not mark the account as created');
assert.match(source, /class_getInstanceVariable\(accountListClass, "needsReloadData"\)/);
assert.match(source, /storage\[ivar_getOffset\(needsReload\)\] = 1/);
assert.match(source, /NSSelectorFromString\(\@"reloadDataIfNeeded"\)/);
assert.match(source, /static void accountListWillAppear/);
assert.match(source, /accountListRefreshPending && markAccountListForReload\(controller\)/);
assert.doesNotMatch(source, /if \(refreshed\) accountListRefreshPending = NO/);
assert.match(source, /if \(marked\) \{[\s\S]*accountListRefreshPending = NO;/);
assert.doesNotMatch(source, /if \(!accountListRefreshPending\) return;\s*accountListRefreshPending = NO;\s*NSUInteger refreshed/);
assert.doesNotMatch(source, /surfaceTrace|offline-routing\.jsonl/,
  'diagnostic logging must not ship in the feature patch');
assert.doesNotMatch(source, /notifyStockRefreshAllViews|refreshAllViewsNotification|markLoanDetailForReload|originalLoanWillAppear|loanDetailRefreshPending/,
  'the obsolete loan-detail refresh workaround must remain removed');
assert.doesNotMatch(source, /loan-detail-state-category-/);
assert.doesNotMatch(source, /reloadActiveBudgetAfterDismissal|accountModelReloadInFlight/);
assert.match(source, /if \(created \|\| \[params\[\@"sync"\] boolValue\]\) markAccountListRefreshPending\(\)/);
const query = source.match(/const char \*query = "([^"]+)";/)?.[1];
assert.ok(query, 'account readback query must remain extractable');
const pairingBudgetQuery = source.match(/const char \*pairingBudgetQuery = "([^"]+)";/)?.[1];
const pairingGroupQuery = source.match(/const char \*pairingGroupQuery = "([^"]+)";/)?.[1];
const pairingCategoryQuery = source.match(/const char \*pairingCategoryQuery = "([^"]+)";/)?.[1];
assert.ok(pairingBudgetQuery && pairingGroupQuery && pairingCategoryQuery,
  'local pairing queries must remain extractable');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ynab-account-readback-'));
try {
  const database = path.join(directory, 'fixture.sqlite');
  execFileSync('/usr/bin/sqlite3', [database, `
    CREATE TABLE Accounts(entityId TEXT, accountName TEXT, accountType TEXT, budgetVersionId TEXT, isTombstone INTEGER);
    CREATE TABLE UserBudgets(userId TEXT, budgetId TEXT, budgetVersionId TEXT, isTombstone INTEGER);
    CREATE TABLE GlobalSettings(settingName TEXT, settingValue TEXT);
    CREATE TABLE MasterCategories(budgetVersionId TEXT, entityId TEXT, isTombstone INTEGER, internalName TEXT, deletable INTEGER, sortableIndex INTEGER, name TEXT, isHidden INTEGER);
    CREATE TABLE SubCategories(budgetVersionId TEXT, entityId TEXT, isTombstone INTEGER, masterCategoryId TEXT, accountId TEXT, internalName TEXT, sortableIndex INTEGER, type TEXT, name TEXT, isHidden INTEGER, goalType TEXT);
    INSERT INTO Accounts VALUES('account','Checking','Checking','version',0),('deleted','Deleted','Checking','version',1);
    INSERT INTO UserBudgets VALUES('current','budget','version',0),('other','other-budget','version',0);
    INSERT INTO GlobalSettings VALUES('lastLoggedInUser','current');
    INSERT INTO MasterCategories VALUES
      ('version','group-live',0,NULL,1,10,'Bills',0),
      ('version','group-hidden',0,NULL,1,20,'Hidden',1),
      ('version','group-internal',0,'Internal',0,30,'Internal',0),
      ('other-version','group-other',0,NULL,1,10,'Other user',0);
    INSERT INTO SubCategories VALUES
      ('version','category-live',0,'group-live',NULL,NULL,10,'DFT','Rent',0,NULL),
      ('version','category-paired',0,'group-live','loan',NULL,20,'DFT','Loan',0,'TB'),
      ('version','category-internal',0,'group-live',NULL,'ImmediateIncomeSubCategory',30,'DFT','Internal row',0,NULL),
      ('version','category-hidden',0,'group-live',NULL,NULL,40,'DFT','Hidden row',1,NULL),
      ('version','category-debt',0,'group-live','credit',NULL,50,'DBT','Card payment',0,NULL),
      ('other-version','category-other',0,'group-other',NULL,NULL,10,'DFT','Other user row',0,NULL);
  `]);
  const read = (accountId, budgetId) => execFileSync('/usr/bin/sqlite3', [
    '-readonly', '-cmd', '.parameter init', '-cmd', `.parameter set ?1 '${accountId}'`,
    '-cmd', `.parameter set ?2 '${budgetId}'`, database, query,
  ], {encoding: 'utf8'}).trim();
  assert.equal(read('account', 'budget'), 'Checking|Checking|version');
  assert.equal(read('account', 'version'), 'Checking|Checking|version', 'the native widget may supply the active budget-version ID');
  assert.equal(read('account', 'other-budget'), '', 'a budget owned by another user must not satisfy readback');
  assert.equal(read('deleted', 'budget'), '', 'tombstoned accounts must not satisfy readback');

  const sql = (statement, value) => execFileSync('/usr/bin/sqlite3', [
    '-readonly', '-cmd', '.parameter init', '-cmd', `.parameter set ?1 '${value}'`, database, statement,
  ], {encoding: 'utf8'}).trim().split('\n').filter(Boolean);
  assert.deepEqual(sql(pairingBudgetQuery, 'budget'), ['version']);
  assert.deepEqual(sql(pairingBudgetQuery, 'version'), ['version']);
  assert.deepEqual(sql(pairingGroupQuery, 'version'), ['group-live|Bills']);
  assert.deepEqual(sql(pairingCategoryQuery, 'version'), [
    'category-live|group-live|Rent|0|0',
    'category-paired|group-live|Loan|1|1',
  ]);
  execFileSync('/usr/bin/sqlite3', [database, "UPDATE GlobalSettings SET settingValue='missing'"]);
  assert.equal(read('account', 'budget'), '', 'logged-out or changed identity must not satisfy readback');
  assert.deepEqual(sql(pairingBudgetQuery, 'budget'), [], 'logged-out identity must not expose categories');
  console.log('Offline account bridge owner, durable account readback, and scoped local pairing categories passed.');
} finally {
  fs.rmSync(directory, {recursive: true});
}
