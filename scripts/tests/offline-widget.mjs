import fs from 'node:fs';
import assert from 'node:assert/strict';
import {patchOfflineWidget} from '../patch-offline-widget.mjs';

const file = process.argv[2];
if (!file) throw new Error('Pass the captured offline widget chunk');
const source = fs.readFileSync(file, 'utf8');
const patched = patchOfflineWidget(source);
assert.throws(() => patchOfflineWidget(patched), /Unsupported/);
assert.match(patched, /window\.mobile\.createBudgetAccount\(e,t\)/);
assert.match(patched, /window\.mobile\.validateBudgetAccount/);
assert.match(patched, /window\.mobile\.categoriesForPairing\(this\.accountWidgetConfig\.budgetId\)/);
assert.doesNotMatch(patched, /return\{categories:\[\]\}/,
  'offline pairing must project the current local categories instead of a placeholder');
assert.match(patched, /0===this\.categoriesService\.categories\.length&&await this\.categoriesService\.loadCategories\(\)/,
  'the captured loan pairing screen must still load the patched response before enabling Skip');
assert.match(patched, /new p\.default\(n,422/);
assert.doesNotMatch(patched, /Creating accounts requires a server connection in this build/);
assert.match(patched, /get deviceVersionCssOverrides\(\)\{if\(this\.deviceService\.iOSDevice\)return"account-widget-ios-26"\}/);
assert.doesNotMatch(patched, /this\.deviceService\.deviceOsVersion&&this\.deviceService\.deviceOsVersion>="26"/);
const marker = 'if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline())return[';
const start = patched.indexOf(marker + '{id:"akahu"') + marker.length;
const end = patched.indexOf('];return await this.createAPIRequest("GET","/api/direct_import/institutions",{query:e})', start);
const order = [...patched.slice(start, end).matchAll(/\{id:"([^"]+)"/g)].map(match => match[1]);
assert.deepEqual(order, ['akahu', 'enablebanking', 'gocardless', 'pluggy', 'simplefin']);
console.log('Offline widget uses stock iOS 26 styling, continues debt validation through optional pairing, uses the native account bridge, and preserves server-equivalent provider ordering.');
