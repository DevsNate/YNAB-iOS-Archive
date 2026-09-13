import fs from 'node:fs';

const replacements = [
  ['customizeBudgetForNewUser(e){return ne(this,arguments,void 0,(function*(e,t=ae.FTUE)', 'customizeBudgetForNewUser(e){return ne(this,arguments,void 0,(function*(e,t=ae.NoCategoriesWizard)'],
  ['createNewBudget(e,t,n,a,i,r){return ne(this,arguments,void 0,(function*(e,t,n,a,i,r,o=null,s=ae.FTUE,d=!1)', 'createNewBudget(e,t,n,a,i,r){return ne(this,arguments,void 0,(function*(e,t,n,a,i,r,o=null,s=ae.NoCategoriesWizard,d=!1)'],
  ['createNewBudgetInternal(e){return ne(this,arguments,void 0,(function*(e,t=ae.FTUE)', 'createNewBudgetInternal(e){return ne(this,arguments,void 0,(function*(e,t=ae.NoCategoriesWizard)'],
  ['let t=ae.FTUE;null!==this.customCategorySet', 'let t=ae.NoCategoriesWizard;null!==this.customCategorySet'],
];

export function patchPlanBootstrap(source) {
  let result = source;
  for (const [oldText, newText] of replacements) {
    const count = result.split(oldText).length - 1;
    if (count !== 1) throw new Error(`plan bootstrap owner count is ${count}, expected 1: ${oldText}`);
    result = result.replace(oldText, newText);
  }
  return result;
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  const path = process.argv[2];
  if (!path) throw new Error('usage: patch-plan-bootstrap.mjs SHARED_LIBRARY.js');
  fs.writeFileSync(path, patchPlanBootstrap(fs.readFileSync(path, 'utf8')));
}
