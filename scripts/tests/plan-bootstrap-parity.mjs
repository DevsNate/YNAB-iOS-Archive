import assert from 'node:assert/strict';
import { patchPlanBootstrap } from '../patch-plan-bootstrap.mjs';

const source = `
customizeBudgetForNewUser(e){return ne(this,arguments,void 0,(function*(e,t=ae.FTUE){return t}))}
createNewBudget(e,t,n,a,i,r){return ne(this,arguments,void 0,(function*(e,t,n,a,i,r,o=null,s=ae.FTUE,d=!1){return s}))}
createNewBudgetInternal(e){return ne(this,arguments,void 0,(function*(e,t=ae.FTUE){return t}))}
let t=ae.FTUE;null!==this.customCategorySet
`;
const patched = patchPlanBootstrap(source);

assert.match(patched, /customizeBudgetForNewUser\(e\).*?t=ae\.NoCategoriesWizard/);
assert.match(patched, /createNewBudget\(e,t,n,a,i,r\).*?s=ae\.NoCategoriesWizard/);
assert.match(patched, /createNewBudgetInternal\(e\).*?t=ae\.NoCategoriesWizard/);
assert.match(patched, /let t=ae\.NoCategoriesWizard;null!==this\.customCategorySet/);
assert.throws(() => patchPlanBootstrap(patched), /expected 1/);
console.log('PASS iOS local plan creation uses the server-compatible emoji template at all four owners');
