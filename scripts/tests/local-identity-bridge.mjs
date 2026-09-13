import fs from 'node:fs';
import assert from 'node:assert/strict';
const s = fs.readFileSync(new URL('../../patches/server-url/YNABServerURLBridge.m', import.meta.url), 'utf8');
assert.match(s, /sqlite3_open_v2/);
assert.match(s, /ynabLocalIdentity/);
assert.match(s, /AccountSettingsMessageHandler/);
assert.match(s, /\[body\[@"action"\] isEqual:@"ynabReadIdentity"\]/);
assert.doesNotMatch(s, /c\[@"ynabLocalIdentity"\]/);
console.log('Local identity bridge is read-only and scoped to the Account Settings message handler');
