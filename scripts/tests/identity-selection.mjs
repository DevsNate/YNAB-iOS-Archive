import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../../patches/server-url/YNABServerURLBridge.m', import.meta.url), 'utf8');
const query = source.match(/sqlite3_prepare_v2\(db, "([^"]+)"/)[1];
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ynab-identity-test-'));
try {
  const database = path.join(directory, 'fixture.sqlite');
  execFileSync('/usr/bin/sqlite3', [database, `
    CREATE TABLE Users(userId TEXT, firstName TEXT, email TEXT);
    CREATE TABLE GlobalSettings(settingName TEXT, settingValue TEXT);
    INSERT INTO Users VALUES('old','Old','old@example.invalid'),('current','Current','current@example.invalid');
    INSERT INTO GlobalSettings VALUES('lastLoggedInUser','current');
  `]);
  const read = () => execFileSync('/usr/bin/sqlite3', ['-readonly', database, query], {encoding:'utf8'}).trim();
  assert.equal(read(), 'Current|current@example.invalid|current');
  execFileSync('/usr/bin/sqlite3', [database, "UPDATE GlobalSettings SET settingValue='missing'"]);
  assert.equal(read(), '', 'missing identity must not fall back to another user');
  execFileSync('/usr/bin/sqlite3', [database, 'DELETE FROM GlobalSettings']);
  assert.equal(read(), '', 'logged-out state must not disclose a cached user');
  console.log('Identity selection: current user, missing user and logged-out fixtures passed.');
} finally {
  fs.rmSync(directory, {recursive:true});
}
