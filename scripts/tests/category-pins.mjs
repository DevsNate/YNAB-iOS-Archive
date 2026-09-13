import assert from 'node:assert/strict';
import {patchCategoryPins} from '../patch-category-pins.mjs';

const source = 'const row={pinnedIndex:n?n.pinnedIndex:null,pinnedGoalIndex:n?n.pinnedGoalIndex:null};';
const patched = patchCategoryPins(source);

assert.doesNotMatch(patched, /pinnedIndex:n\?n\.pinnedIndex:null,pinnedGoalIndex:n\?n\.pinnedGoalIndex:null/);
assert.match(patched, /pinned_index/);
assert.match(patched, /pinned_goal_index/);
assert.throws(() => patchCategoryPins(patched), /already-patched|Unsupported/);
console.log('PASS iOS sync adopts server category pins and Current Goal values');
