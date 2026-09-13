import fs from 'node:fs';
import vm from 'node:vm';
import {pathToFileURL} from 'node:url';

const dispatchOwner = 'const a=t.charAt(0).toUpperCase()+t.slice(1),i=o().mobileTransactionManager.executeAction(n,rc[a]);';
const createActionOwner = 'te([eo],sy.prototype,"perform",null);';
const revolvingCreditCategoryOwner = 'createCreditCardPaymentCategoryIfNeeded(e){if(e.accountType===Fe.CreditCard){';
const revolvingCreditCategoryReplacement = 'createCreditCardPaymentCategoryIfNeeded(e){if(Pe.isCreditAccount(e.accountType)){';

export function patchRevolvingCreditCategory(source) {
  if (source.includes(revolvingCreditCategoryReplacement) ||
      source.split(revolvingCreditCategoryOwner).length !== 2) {
    throw new Error('Unsupported or already-patched revolving-credit category owner');
  }
  return source.replace(revolvingCreditCategoryOwner, revolvingCreditCategoryReplacement);
}

export function patchAccountAction(source) {
  if (source.includes('ynabCreateOfflineAccount') || source.includes('class YnabOfflineCreateAccountAction') ||
      source.split(dispatchOwner).length !== 2 || source.split(createActionOwner).length !== 2 ||
      source.split(revolvingCreditCategoryOwner).length !== 2 ||
      !source.includes('class sy{constructor(e){this.entityManager=e') ||
      !source.includes('class Mm{constructor(e){this.entityManager=e')) {
    throw new Error('Unsupported shared-library account action owner');
  }

  const composite = `class YnabOfflineCreateAccountAction{constructor(e){this.entityManager=e}perform(e){return ne(this,void 0,void 0,(function*(){const t=yield new sy(this.entityManager).perform(e.account);if(t.err)return t;const n=t.value;if(n.setSortableIndex(e.sortableIndex),e.pair){const t=yield new Mm(this.entityManager).perform(e.pair,n.entityId);if(t.err)return Xr(t.value)}return Jr(n)}))}}te([eo],YnabOfflineCreateAccountAction.prototype,"perform",null);`;
  let patched = patchRevolvingCreditCategory(source).replace(createActionOwner, createActionOwner + composite);

  const branch = `if(t==="ynabValidateOfflineAccount"||t==="ynabCreateOfflineAccount"){
    const lib=o(), invalid=(errorCode,field,message)=>({ok:false,errorCode,field,message}), raw=n&&n.payload;
    const budgetMatches=n&&(n.budgetId===lib.activeBudgetVersionId||n.budgetId===(lib.activeBudget&&lib.activeBudget.budgetId));
    if(!lib.loggedInUser||!lib.activeBudget||!raw||!budgetMatches) throw new Error("Active budget changed or is unavailable");
    if(raw.is_migrating_to_debt_account===true) return invalid("OfflineMigrationUnavailable","type","Converting an existing account is unavailable while offline.");
    const name=typeof raw.name==="string"?raw.name.trim():"", type=raw.type, dateText=raw.starting_balance_date;
    if(!name) return invalid("InvalidAccountName","name","The account name is required.");
    if(typeof type!=="string"||!Object.values(Fe).includes(type)) return invalid("InvalidAccountType","type","Select a valid account type.");
    if(!Number.isSafeInteger(raw.balance)) return invalid("InvalidBalance","balance","Enter a valid current balance.");
    if(typeof dateText!=="string"||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(dateText)) return invalid("InvalidStartingBalanceDate","starting_balance_date","Enter a valid starting-balance date.");
    const startingBalanceDate=Be.createFromISOString(dateText);
    if(!startingBalanceDate.isValid()||startingBalanceDate.toISOString()!==dateText) return invalid("InvalidStartingBalanceDate","starting_balance_date","Enter a valid starting-balance date.");
    const month=dateText.slice(0,7)+"-01", monthly=value=>{if(value==null)return null;let values;try{values=typeof value==="string"?JSON.parse(value):value}catch{return NaN}if(!values||typeof values!=="object"||Array.isArray(values))return NaN;return Number.isSafeInteger(values[month])?values[month]:NaN};
    const loan=Pe.isLoanAccount(type), interestRate=loan?monthly(raw.debt_interest_rates):0, minimumPayment=loan?monthly(raw.debt_minimum_payments):0, rawEscrow=loan?monthly(raw.debt_escrow_amounts):0, escrowAmount=rawEscrow==null?0:rawEscrow;
    if(loan&&(!Number.isSafeInteger(interestRate)||interestRate<0)) return invalid("InvalidInterestRate","debt_interest_rates","Enter a valid interest rate.");
    if(loan&&(!Number.isSafeInteger(minimumPayment)||minimumPayment<0)) return invalid("InvalidMinimumPayment","debt_minimum_payments","Enter a valid minimum payment.");
    if(type===Fe.Mortgage&&(!Number.isSafeInteger(escrowAmount)||escrowAmount<0)) return invalid("InvalidEscrowAmount","debt_escrow_amounts","Enter a valid escrow amount.");
    let pair=null;const paired=raw.paired_sub_category, emptyPairing=paired&&typeof paired==="object"&&!Array.isArray(paired)&&["id","name","master_category_id","master_category_name"].every((key=>paired[key]==null||typeof paired[key]==="string"&&!paired[key].trim()));
    if(paired!=null&&!emptyPairing){
      if(!loan||typeof paired!=="object"||Array.isArray(paired)) return invalid("InvalidNewSubCategoryToPair","paired_sub_category","Select a valid category.");
      if(typeof paired.id==="string"&&paired.id) pair={existingSubCategoryId:paired.id};
      else if(typeof paired.name==="string"&&paired.name.trim()){
        if(typeof paired.master_category_id==="string"&&paired.master_category_id) pair={existingMasterCategoryId:paired.master_category_id,newSubCategoryName:paired.name.trim()};
        else if(typeof paired.master_category_name==="string"&&paired.master_category_name.trim()) pair={newMasterCategoryName:paired.master_category_name.trim(),newSubCategoryName:paired.name.trim()};
        else return invalid("InvalidNewMasterCategoryToPair","paired_sub_category","Select a valid category group.");
      }else return invalid("InvalidNewSubCategoryToPair","paired_sub_category","Enter a valid category name.");
    }
    const account={accountName:name,accountType:type,startingBalance:raw.balance,startingBalanceDate,interestRate,minimumPayment,escrowAmount};
    const validation=new sy(lib.entityManager).validateInput(account).andThen((()=>new sy(lib.entityManager).validateName(name)));
    if(validation.err)return invalid(validation.value.__code||"OfflineAccountValidationFailed",validation.value.__code==="AlreadyTakenAccountName"?"name":null,validation.value.__code==="AlreadyTakenAccountName"?"An account with this name already exists.":"The account details are invalid.");
    if(t==="ynabValidateOfflineAccount")return{ok:true};
    const accounts=lib.entityManager.getAllNonTombstonedAccounts(),sortableIndex=accounts.reduce(((value,account)=>Math.max(value,Number.isFinite(account.sortableIndex)?account.sortableIndex:0)),-100)+100;
    const result=yield new YnabOfflineCreateAccountAction(lib.entityManager).perform({account,pair,sortableIndex});
    if(result.err)return invalid(result.value.__code||"OfflineAccountValidationFailed",null,"The account details could not be saved.");
    // The stock create action persists the account and its starting transaction,
    // but pending account/month calculations are a separate store lifecycle.
    // Run that lifecycle after the composite change set closes so loan screens
    // receive the same AccountMonthlyCalculations as a synced account.
    lib.store.performPendingCalculationsOnActiveBudget(false);
    const created=result.value;
    return{ok:true,id:created.entityId,account_name:created.accountName,account_type:created.accountType,budgetVersionId:lib.activeBudgetVersionId};
  }`;
  patched = patched.replace(dispatchOwner, branch + dispatchOwner);
  new vm.Script(patched);
  return patched;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  if (!file) throw new Error('Usage: node patch-account-action.mjs shared-library.js');
  fs.writeFileSync(file, patchAccountAction(fs.readFileSync(file, 'utf8')));
}
