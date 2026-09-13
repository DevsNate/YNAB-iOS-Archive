#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}; root=${script_dir:h}; input=${1:-}; output=${2:-}
if [[ -z "$input" || -z "$output" ]]; then print -u2 "usage: $0 neutral.ipa output.ipa [neutral-receipt.json]"; exit 64; fi
for tool in clang codesign find node plutil ruby shasum unzip zsign; do command -v "$tool" >/dev/null || { print -u2 "required tool not found: $tool"; exit 69; }; done
[[ -x /usr/libexec/PlistBuddy ]] || { print -u2 'PlistBuddy is required'; exit 69; }
expected=$(plutil -extract baseline.sha256 raw -o - "$root/baseline/manifest.json")
actual=$(shasum -a 256 "$input" | awk '{print $1}')
receipt=${3:-"$input.neutral.json"}
[[ -f "$receipt" ]] || { print -u2 'Missing neutral build receipt; run build-pure.sh first'; exit 65; }
[[ "$(plutil -extract baseline_sha256 raw -o - "$receipt")" == "$expected" &&
   "$(plutil -extract neutral_sha256 raw -o - "$receipt")" == "$actual" ]] ||
   { print -u2 'Neutral IPA does not match its baseline/build receipt'; exit 65; }
[[ ! -e "$output" && "${output:A}" != "$root"/* ]] || { print -u2 'output must be a new file outside the repository'; exit 65; }
stage=$(mktemp -d /tmp/ynab-ios-url.XXXXXX); trap 'rm -rf "$stage"' EXIT
unzip -q "$input" -d "$stage/source"
app=$(find "$stage/source/Payload" -maxdepth 1 -type d -name '*.app' -print -quit); [[ -n "$app" ]] || exit 65
zsh "$script_dir/install-offline-assets.sh" "$app"
binary="$app/$(plutil -extract CFBundleExecutable raw -o - "$app/Info.plist")"; shared="$app/YNABSharedLibMobile.packaged.min.js"
node "$script_dir/patch-plan-bootstrap.mjs" "$shared"
node "$script_dir/patch-category-pins.mjs" "$shared"
ruby - "$binary" <<'RUBY'
path=ARGV.fetch(0); d=File.binread(path); old='^.+@([A-Za-z0-9-]+\\.)+[A-Za-z]{2}[A-Za-z]*$'.b
new='(?is)^\s*https?://.+?\s*$'.b
ins=[0xd2800568].pack('L<'); rep=[0xd2800008 | (new.bytesize << 5)].pack('L<')
raise 'validator occurrence mismatch' unless d.scan(old).length==1 && d.scan(ins).length==1
raise 'validator exceeds stock storage' unless new.bytesize <= old.bytesize
d.sub!(old,new+"\0"*(old.bytesize-new.bytesize)); d.sub!(ins,rep); File.binwrite(path,d)
RUBY
ruby - "$shared" <<'RUBY'
path=ARGV.fetch(0); d=File.binread(path)
old='e.loginUser=function(e,t){return ne(this,arguments,void 0,(function*(e,t,n=null){return yield oe((()=>ne(this,void 0,void 0,(function*(){const a=yield s().loginUser(e,t,!1,""===n?null:n);return ie.info("Login completed."),m(o().store,a)}))))}))}'
new='e.loginUser=function(e,t){return ne(this,arguments,void 0,(function*(e,t,n=null){return yield oe((()=>ne(this,void 0,void 0,(function*(){const a="function"==typeof ynabSelectServerURL?ynabSelectServerURL(e):"";if(!a)throw new Error("Invalid server URL");o().apiAdapter.config.serverUrl=a;const i=yield s().loginUser("local@ynab5.invalid",t,!1,""===n?null:n);return ie.info("Login completed."),m(o().store,i)}))))}))}'
raise 'login owner occurrence mismatch' unless d.scan(old).length==1; d.sub!(old,new)
old='function c(e,t){return ne(this,void 0,void 0,(function*(){return yield oe((()=>ne(this,void 0,void 0,(function*(){return yield s().loginUserWithSessionToken(t),ie.info("loginUserWithSessionToken completed."),m(o().store,t)}))))}))}'
new='function c(e,t){return ne(this,void 0,void 0,(function*(){return yield oe((()=>ne(this,void 0,void 0,(function*(){const n="function"==typeof ynabConfiguredServerURL?ynabConfiguredServerURL():"";n&&(o().apiAdapter.config.serverUrl=n);return yield s().loginUserWithSessionToken(t),ie.info("loginUserWithSessionToken completed."),m(o().store,t)}))))}))}'
raise 'session owner occurrence mismatch' unless d.scan(old).length==1; d.sub!(old,new); File.binwrite(path,d)
RUBY
node "$script_dir/patch-profile-action.mjs" "$shared"
node "$script_dir/patch-account-action.mjs" "$shared"
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$app/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSLocalNetworkUsageDescription' "$app/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string Connect to the budgeting server entered on this device.' "$app/Info.plist"
sdk=$(xcrun --sdk iphoneos --show-sdk-path); bridge="$stage/YNABServerURLBridge.dylib"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=18.0 -fobjc-arc -fmodules -dynamiclib -install_name '@executable_path/YNABServerURLBridge.dylib' -framework Foundation -framework JavaScriptCore -framework UIKit -framework WebKit "$root/patches/server-url/YNABServerURLBridge.m" "$root/patches/server-url/Endpoint.m" -o "$bridge"
codesign --force --sign - "$bridge"
mkdir -p "${output:h}"; zsign -f -a -R -l "$bridge" -o "$stage/candidate.ipa" "$app" >/dev/null
unzip -q "$stage/candidate.ipa" -d "$stage/check"
checked="$stage/check/Payload/$(basename "$app")"
[[ -d "$checked" && -f "$checked/YNABServerURLBridge.dylib" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$checked/Info.plist")" == "$(plutil -extract bundleIdentifier raw -o - "$root/baseline/manifest.json")" ]]
codesign --verify --deep --strict "$checked"
otool -L "$checked/$(basename "$binary")" | grep -Fq '@executable_path/YNABServerURLBridge.dylib'
[[ -z "$(find "$checked" -name embedded.mobileprovision -print -quit)" ]]
cmp "$shared" "$checked/YNABSharedLibMobile.packaged.min.js"
diff -rq "$app/YNABOffline" "$checked/YNABOffline"
# Publish only after the candidate has passed the package gates.
mv "$stage/candidate.ipa" "$output"
print "built current iOS patches: $output"; print "neutral_input_sha256=$actual"
