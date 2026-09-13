import fs from 'node:fs';
import vm from 'node:vm';
import {pathToFileURL} from 'node:url';

// The existing native mobileTransactionManagerExecute entry already marshals
// state into the shared-library execution context. Extend that dispatch rather
// than invoking JavaScriptCore from an arbitrary WebKit callback thread.
export function patchProfileAction(source) {
  const anchor = 'const a=t.charAt(0).toUpperCase()+t.slice(1),i=o().mobileTransactionManager.executeAction(n,rc[a]);';
  const owner = 'class Fc{constructor(e){this.entityManager=e}perform(e,t)';
  if (source.includes('ynabOfflineSetFirstName') || source.split(anchor).length !== 2 || source.split(owner).length !== 2 ||
      !source.includes('te([eo],Fc.prototype,"perform",null)')) {
    throw new Error('Unsupported shared-library profile/action owner');
  }
  const branch = `if(t==="ynabOfflineSetFirstName"){
    const lib=o(), user=lib.loggedInUser;
    if(!user || !n || n.userId!==user.userId) throw new Error("Profile user changed");
    if(typeof n.firstName!=="string") throw new Error("Invalid first name");
    const name=n.firstName.trim();
    if(!name || name.length>100) throw new Error("Invalid first name");
    const result=yield new Fc(lib.entityManager).perform(user.userId,name);
    if(!result.ok || result.err) throw new Error("Profile change rejected");
    if(lib.store.syncCatalogDataWithLocalStorage()!==true) throw new Error("Local profile persistence failed");
    return {saved:true,userId:user.userId,firstName:lib.loggedInUser.firstName,email:lib.loggedInUser.email};
  }`;
  const patched = source.replace(anchor, branch + anchor);
  new vm.Script(patched);
  return patched;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  if (!file) throw new Error('Usage: node patch-profile-action.mjs shared-library.js');
  fs.writeFileSync(file, patchProfileAction(fs.readFileSync(file, 'utf8')));
}
