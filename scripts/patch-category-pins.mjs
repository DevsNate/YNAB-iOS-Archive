import fs from 'node:fs';

const stockMapper = 'pinnedIndex:n?n.pinnedIndex:null,pinnedGoalIndex:n?n.pinnedGoalIndex:null';
const serverMapper = 'pinnedIndex:null!==t.pinned_index&&void 0!==t.pinned_index?t.pinned_index:null,pinnedGoalIndex:null!==t.pinned_goal_index&&void 0!==t.pinned_goal_index?t.pinned_goal_index:null';

// The server owns the canonical category pin and Current Goal values. Stock's
// mapper keeps the local values when a row is reconciled, so a change made on
// the other client never reaches the iOS model. Apply this only to the
// temporary patched IPA bundle; the sealed Stock input remains unchanged.
export function patchCategoryPins(source) {
  if (source.includes(serverMapper) || source.split(stockMapper).length !== 2) {
    throw new Error('Unsupported or already-patched category pin mapper');
  }
  return source.replace(stockMapper, serverMapper);
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  const file = process.argv[2];
  if (!file) throw new Error('Usage: node patch-category-pins.mjs shared-library.js');
  fs.writeFileSync(file, patchCategoryPins(fs.readFileSync(file, 'utf8')));
}
