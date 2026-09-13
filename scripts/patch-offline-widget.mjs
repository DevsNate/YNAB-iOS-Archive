import fs from 'node:fs';
import vm from 'node:vm';
import {pathToFileURL} from 'node:url';

const providerPrefix = 'if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline())return[';
const providerMarker = providerPrefix + '{id:"simplefin"';
const providerSuffix = '];return await this.createAPIRequest("GET","/api/direct_import/institutions",{query:e})';
const createOwner = 'async createBudgetAccount(e,t){if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline()){throw new Error("Creating accounts requires a server connection in this build.")}return await this.createAPIRequest("POST",`/api/direct_import/budgets/${e}/accounts`,{body:t})}';
const validateOwner = 'async validateUnlinkedAccount(e){return await this.createRequest("validate_unlinked_account",e)}';
const categoriesOwner = 'async categoriesForPairing(){return await this.createRequest("categories_for_pairing")}';
const deviceVersionOwner = 'get deviceVersionCssOverrides(){if(this.deviceService.iOSDevice&&this.deviceService.deviceOsVersion&&this.deviceService.deviceOsVersion>="26")return"account-widget-ios-26"}';
const offlineDeviceVersionOwner = 'get deviceVersionCssOverrides(){if(this.deviceService.iOSDevice)return"account-widget-ios-26"}';

function splitProviderObjects(source) {
  const objects = [];
  let start = 0;
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === '"' || character === "'") quote = character;
    else if (character === '{') depth += 1;
    else if (character === '}') depth -= 1;
    else if (character === ',' && depth === 0) {
      objects.push(source.slice(start, index));
      start = index + 1;
    }
  }
  objects.push(source.slice(start));
  return objects;
}

export function patchOfflineWidget(source) {
  if (source.includes('offlineAccountValidationError(e)') || source.split(providerMarker).length !== 2 ||
      source.split(providerSuffix).length !== 2 || source.split(createOwner).length !== 2 ||
      source.split(validateOwner).length !== 2 || source.split(categoriesOwner).length !== 2 ||
      source.split(deviceVersionOwner).length !== 2) {
    throw new Error('Unsupported or already-patched offline account widget');
  }

  const providerStart = source.indexOf(providerMarker) + providerPrefix.length;
  const providerEnd = source.indexOf(providerSuffix, providerStart);
  const providers = splitProviderObjects(source.slice(providerStart, providerEnd));
  const byId = new Map(providers.map(provider => {
    const id = provider.match(/^\{id:"([^"]+)"/)?.[1];
    return [id, provider];
  }));
  const expected = ['simplefin', 'gocardless', 'pluggy', 'enablebanking', 'akahu'];
  if (providers.length !== expected.length || expected.some(id => !byId.has(id))) {
    throw new Error('Offline provider inventory changed');
  }
  const ordered = ['akahu', 'enablebanking', 'gocardless', 'pluggy', 'simplefin']
    .map(id => byId.get(id)).join(',');
  let patched = source.slice(0, providerStart) + ordered + source.slice(providerEnd);

  const createReplacement = `offlineAccountValidationError(e){const t={InvalidAccountName:"name",AlreadyTakenAccountName:"name",InvalidAccountType:"type",AccountTypeRequired:"type",InvalidBalance:"balance",InvalidStartingBalanceDate:"starting_balance_date",InvalidInterestRate:"debt_interest_rates",InvalidMinimumPayment:"debt_minimum_payments",InvalidEscrowAmount:"debt_escrow_amounts",SubCategoryToPairNotFound:"paired_sub_category",AccountAlreadyPairedToDifferentSubCategory:"paired_sub_category",SubCategoryAlreadyPairedToDifferentAccount:"paired_sub_category",MasterCategoryToPairNotFound:"paired_sub_category",InvalidNewMasterCategoryToPair:"paired_sub_category",InvalidNewSubCategoryToPair:"paired_sub_category"}[e.errorCode]||e.field||"name",n=e.message||"The account details could not be saved.";return new p.default(n,422,{errors:{[t]:[n]}})}async createBudgetAccount(e,t){if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline()){if("function"!=typeof window.mobile.createBudgetAccount)throw new Error("The local account bridge is unavailable.");const n=await window.mobile.createBudgetAccount(e,t);if(n&&n.errorCode)throw this.offlineAccountValidationError(n);return n}return await this.createAPIRequest("POST",\`/api/direct_import/budgets/\${e}/accounts\`,{body:t})}`;
  patched = patched.replace(createOwner, createReplacement);
  const validateReplacement = 'async validateUnlinkedAccount(e){if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline()){if("function"!=typeof window.mobile.validateBudgetAccount)throw new Error("The local account bridge is unavailable.");const t=await window.mobile.validateBudgetAccount(this.accountWidgetConfig.budgetId,e);if(t&&t.errorCode)throw this.offlineAccountValidationError(t);return{}}return await this.createRequest("validate_unlinked_account",e)}';
  patched = patched.replace(validateOwner, validateReplacement);
  // Loan validation advances to the optional category-pairing screen. That
  // screen always loads this endpoint before its Skip action becomes usable.
  // The native bridge projects the active budget's local SQLite categories
  // read-only in the exact grouped shape consumed by the pairing screen.
  const categoriesReplacement = 'async categoriesForPairing(){if(window.mobile&&window.mobile.isOnline&&!window.mobile.isOnline()){if("function"!=typeof window.mobile.categoriesForPairing)throw new Error("The local category bridge is unavailable.");return await window.mobile.categoriesForPairing(this.accountWidgetConfig.budgetId)}return await this.createRequest("categories_for_pairing")}';
  patched = patched.replace(categoriesOwner, categoriesReplacement);
  // This transform runs only on the bundled iOS fallback. Preserve the stock
  // iOS 26 class and its captured radius tokens even when WKWebView does not
  // expose the OS-version string in the shape expected by the Web runtime.
  patched = patched.replace(deviceVersionOwner, offlineDeviceVersionOwner);
  new vm.Script(patched);
  return patched;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  if (!file) throw new Error('Usage: node patch-offline-widget.mjs widget-chunk.js');
  fs.writeFileSync(file, patchOfflineWidget(fs.readFileSync(file, 'utf8')));
}
