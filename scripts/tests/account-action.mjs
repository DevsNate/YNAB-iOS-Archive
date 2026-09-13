import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {patchAccountAction} from '../patch-account-action.mjs';

const file = process.argv[2];
if (!file) throw new Error('Pass the sealed stock shared-library JS path');
const source = fs.readFileSync(file, 'utf8');
const patched = patchAccountAction(source);
assert.throws(() => patchAccountAction(patched), /Unsupported/);
assert.throws(() => patchAccountAction(source.replace('class sy{', 'class Renamed{')), /Unsupported/);
assert.match(patched, /class YnabOfflineCreateAccountAction/);
assert.match(patched, /new sy\(this\.entityManager\)\.perform/);
assert.match(patched, /new Mm\(this\.entityManager\)\.perform/);
assert.match(patched, /te\(\[eo\],YnabOfflineCreateAccountAction\.prototype,"perform",null\)/);
assert.match(patched, /createCreditCardPaymentCategoryIfNeeded\(e\)\{if\(Pe\.isCreditAccount\(e\.accountType\)\)\{/);

const start = patched.indexOf('if(t==="ynabValidateOfflineAccount"');
const end = patched.indexOf('const a=t.charAt(0)', start);
const branch = patched.slice(start, end);
const calls = [];
let calculationRuns = 0;
const lifecycle = [];
let duplicate = false;
let persistenceFailure = false;
const Fe = Object.freeze(Object.fromEntries(['Checking', 'Savings', 'CreditCard', 'Cash', 'LineOfCredit',
  'Mortgage', 'AutoLoan', 'StudentLoan', 'PersonalLoan', 'MedicalDebt', 'OtherDebt',
  'OtherAsset', 'OtherLiability'].map(type => [type, type])));
const loanTypes = new Set(['Mortgage', 'AutoLoan', 'StudentLoan', 'PersonalLoan', 'MedicalDebt', 'OtherDebt']);
const entityManager = {getAllNonTombstonedAccounts: () => [{sortableIndex: 0}, {sortableIndex: 200}]};
const lib = {loggedInUser: {userId: 'user'}, activeBudget: {budgetId: 'budget'}, activeBudgetVersionId: 'version', entityManager,
  store: {performPendingCalculationsOnActiveBudget: () => { calculationRuns += 1; lifecycle.push('calculations'); return true; }}};
class DateValue {
  constructor(value) { this.value = value; }
  isValid() { return this.value !== '2026-02-31'; }
  toISOString() { return this.value; }
}
class AccountAction {
  validateInput() { return {andThen: callback => callback()}; }
  validateName() { return duplicate ? {err: true, value: {__code: 'AlreadyTakenAccountName'}} : {err: false}; }
}
class CompositeAction {
  async perform(input) {
    lifecycle.push('create-start');
    calls.push(input);
    if (persistenceFailure) throw new Error('disk failed');
    lifecycle.push('create-end');
    return {ok: true, err: false, value: {entityId: 'new-account', accountName: input.account.accountName, accountType: input.account.accountType}};
  }
}
const context = vm.createContext({
  o: () => lib,
  Fe,
  Pe: {isLoanAccount: type => loanTypes.has(type)},
  Be: {createFromISOString: value => new DateValue(value)},
  sy: AccountAction,
  YnabOfflineCreateAccountAction: CompositeAction,
  Number,
  JSON,
});
const run = vm.runInContext(`async function run(n,t){${branch.replaceAll('yield ', 'await ')}return 'stock-dispatch'};run`, context);
const checking = {name: ' Checking ', type: 'Checking', balance: 125000, starting_balance_date: '2026-09-10',
  paired_sub_category: {id: null, name: null, master_category_id: null, master_category_name: null},
  is_migrating_to_debt_account: false};
assert.equal(JSON.stringify(await run({budgetId: 'budget', payload: checking}, 'ynabValidateOfflineAccount')), '{"ok":true}');
const created = await run({budgetId: 'budget', payload: checking}, 'ynabCreateOfflineAccount');
assert.equal(created.id, 'new-account');
assert.equal(calls[0].account.accountName, 'Checking');
assert.equal(calls[0].sortableIndex, 300);
assert.equal(calls[0].pair, null);
assert.equal(calculationRuns, 1, 'offline creation must run pending calculations after persistence');
assert.deepEqual(lifecycle, ['create-start', 'create-end', 'calculations'], 'the calculation hook must run after the composite action returns');

const mortgage = {...checking, name: 'Mortgage', type: 'Mortgage', balance: -200000000,
  debt_interest_rates: '{"2026-09-01":6500}', debt_minimum_payments: '{"2026-09-01":1250000}',
  debt_escrow_amounts: '{"2026-09-01":400000}', paired_sub_category: {id: 'category'}};
await run({budgetId: 'budget', payload: mortgage}, 'ynabCreateOfflineAccount');
assert.equal(calls[1].account.interestRate, 6500);
assert.equal(JSON.stringify(calls[1].pair), '{"existingSubCategoryId":"category"}');

for (const type of Object.values(Fe)) {
  const payload = {...checking, name: `Offline ${type}`, type};
  if (loanTypes.has(type)) Object.assign(payload, {
    debt_interest_rates: '{"2026-09-01":6500}', debt_minimum_payments: '{"2026-09-01":1250000}',
    debt_escrow_amounts: type === Fe.Mortgage ? '{"2026-09-01":400000}' : null,
  });
  const result = await run({budgetId: 'budget', payload}, 'ynabCreateOfflineAccount');
  assert.equal(result.ok, true, `offline ${type} should use the stock account owner`);
}

const callsBeforeDuplicate = calls.length;
duplicate = true;
const duplicateResult = await run({budgetId: 'budget', payload: checking}, 'ynabCreateOfflineAccount');
assert.equal(duplicateResult.errorCode, 'AlreadyTakenAccountName');
assert.equal(calls.length, callsBeforeDuplicate, 'duplicate validation must not execute the create action');
duplicate = false;
for (const payload of [
  {...checking, balance: 1.5},
  {...checking, type: 'Unknown'},
  {...checking, starting_balance_date: '2026-02-31'},
]) {
  const result = await run({budgetId: 'budget', payload}, 'ynabCreateOfflineAccount');
  assert.equal(result.ok, false);
}
persistenceFailure = true;
await assert.rejects(run({budgetId: 'budget', payload: checking}, 'ynabCreateOfflineAccount'), /disk failed/);
await assert.rejects(run({budgetId: 'other', payload: checking}, 'ynabCreateOfflineAccount'), /Active budget changed/);
persistenceFailure = false;
await run({budgetId: 'version', payload: checking}, 'ynabCreateOfflineAccount');
assert.equal(await run({}, 'save'), 'stock-dispatch');
console.log('Offline account action guards, payload mapping, duplicate rejection, stock dispatch isolation and failure propagation passed.');
