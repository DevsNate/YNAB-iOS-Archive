import fs from 'node:fs';
import assert from 'node:assert/strict';

const fixturePath = new URL('../../../YNAB-KB/Engineering-KB/contracts/account-widget-pairing-eligibility.json', import.meta.url);
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const source = fs.readFileSync(new URL('../../patches/server-url/YNABServerURLBridge.m', import.meta.url), 'utf8');

assert.equal(fixture.contract, 'account-widget-pairing-eligibility');
assert.deepEqual(fixture.groups.include, ['not_tombstoned', 'visible', 'deletable']);
assert.deepEqual(fixture.categories.include, [
  'not_tombstoned', 'visible', 'ordinary_dft', 'not_internal', 'parent_group_included',
]);
assert.match(source, /isTombstone = 0 AND isHidden = 0 AND deletable = 1/);
assert.match(source, /isTombstone = 0 AND isHidden = 0 AND type = 'DFT' AND internalName IS NULL/);
assert.match(source, /ORDER BY sortableIndex, entityId/);
for (const excluded of fixture.excluded_fixture) {
  if (excluded.reason === 'payment') assert.match(source, /type = 'DFT'/);
  if (excluded.reason === 'internal') assert.match(source, /internalName IS NULL/);
  if (excluded.reason === 'nondeletable') assert.match(source, /deletable = 1/);
}
console.log('iOS pairing projection validates the shared eligibility contract fixture.');
