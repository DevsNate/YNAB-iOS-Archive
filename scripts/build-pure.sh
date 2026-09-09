#!/bin/zsh
set -euo pipefail

# Produce the first clean transformation of the sealed iOS 26.32 baseline.
# This step changes signing state only. It deliberately does not rename the
# app, inject a dylib, add transport permissions, or alter native behavior.

script_dir=${0:A:h}
project_root=${script_dir:h}
default_output="$project_root/../YNAB-Output/iOS/YNAB-26.32-pure-signer-neutral.ipa"

input_ipa=${1:-}
output_ipa=${2:-$default_output}
expected_input_sha256=$(plutil -extract baseline.sha256 raw -o - "$project_root/baseline/manifest.json")

if [[ -z "$input_ipa" ]]; then
  print -u2 "usage: $0 /path/to/stock-26.32-build-735.ipa [output.ipa]"
  exit 64
fi

if [[ ! -f "$input_ipa" ]]; then
  print -u2 "missing input IPA: $input_ipa"
  exit 66
fi
if ! command -v zsign >/dev/null 2>&1; then
  print -u2 'zsign is required but was not found'
  exit 69
fi

if [[ -e "$output_ipa" || -e "$output_ipa.neutral.json" || "${output_ipa:A}" == "$project_root"/* ]]; then
  print -u2 'output must be a new file outside the repository'
  exit 65
fi

actual_input_sha256=$(shasum -a 256 "$input_ipa" | awk '{print $1}')
if [[ "$actual_input_sha256" != "$expected_input_sha256" ]]; then
  print -u2 'refusing to build from an unsealed input IPA'
  print -u2 "expected=$expected_input_sha256"
  print -u2 "actual=$actual_input_sha256"
  exit 65
fi

work_dir=$(mktemp -d /tmp/ynab-ios-2632-neutral.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/source" "$work_dir/output" "${output_ipa:h}"

unzip -q "$input_ipa" -d "$work_dir/source"
zsign -f -a -R -o "$output_ipa" "$input_ipa" >/dev/null
unzip -q "$output_ipa" -d "$work_dir/output"

source_app=$(find "$work_dir/source/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)
output_app=$(find "$work_dir/output/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)
if [[ -z "$source_app" || -z "$output_app" ]]; then
  print -u2 'source or output IPA has no Payload/*.app'
  exit 65
fi

# Signing must not add, remove, or rename product files. CodeResources and the
# Mach-O signature regions may change, but the archive surface stays stock.
(cd "$source_app" && find . -type f -print | LC_ALL=C sort) > "$work_dir/source-files.txt"
(cd "$output_app" && find . -type f -print | LC_ALL=C sort) > "$work_dir/output-files.txt"
if ! cmp -s "$work_dir/source-files.txt" "$work_dir/output-files.txt"; then
  print -u2 'neutrality validation failed: archive file surface changed'
  diff -u "$work_dir/source-files.txt" "$work_dir/output-files.txt" >&2 || true
  exit 1
fi

expected_bundle_ids=(
  'com.youneedabudget.evergreen.YNAB-Evergreen'
  'com.youneedabudget.evergreen.YNAB-Evergreen.YNABWidget'
  'com.youneedabudget.evergreen.YNAB-Evergreen.YNABWidgetIntentHandler'
)
output_bundles=(
  "$output_app"
  "$output_app/PlugIns/YNABWidgetExtension.appex"
  "$output_app/PlugIns/YNABWidgetIntentHandler.appex"
)

for index in 1 2 3; do
  bundle=${output_bundles[$index]}
  expected_bundle_id=${expected_bundle_ids[$index]}
  if [[ ! -d "$bundle" ]]; then
    print -u2 "neutrality validation failed: missing bundle $bundle"
    exit 1
  fi

  actual_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Info.plist")
  if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
    print -u2 "neutrality validation failed: expected=$expected_bundle_id actual=$actual_bundle_id"
    exit 1
  fi

  executable_name=$(plutil -extract CFBundleExecutable raw -o - "$bundle/Info.plist")
  executable="$bundle/$executable_name"
  codesign --verify --strict "$bundle" 2>/dev/null
  entitlements=$(codesign -d --entitlements :- "$executable" 2>/dev/null)
  if [[ -n "$entitlements" ]]; then
    print -u2 "neutrality validation failed: signer entitlements remain in $actual_bundle_id"
    exit 1
  fi
done

if find "$output_app" -name embedded.mobileprovision -print -quit | grep -q .; then
  print -u2 'neutrality validation failed: embedded provisioning profile present'
  exit 1
fi

output_name=$(plutil -extract CFBundleDisplayName raw -o - "$output_app/Info.plist")
output_refresh=$(plutil -extract BGTaskSchedulerPermittedIdentifiers.0 raw -o - "$output_app/Info.plist")
output_shortcut=$(plutil -extract UIApplicationShortcutItems.0.UIApplicationShortcutItemType raw -o - "$output_app/Info.plist")
if [[ "$output_name" != 'YNAB' ||
      "$output_refresh" != 'com.youneedabudget.evergreen.YNAB-Evergreen.refresh' ||
      "$output_shortcut" != 'com.youneedabudget.evergreen.YNAB-Evergreen.newtransaction' ]]; then
  print -u2 'neutrality validation failed: stock role metadata changed'
  exit 1
fi

main_executable_name=$(plutil -extract CFBundleExecutable raw -o - "$output_app/Info.plist")
if otool -L "$output_app/$main_executable_name" |
    rg -q 'YNAB5|Eevee|decrypter|substrate|substitute'; then
  print -u2 'neutrality validation failed: injected runtime dependency found'
  exit 1
fi

output_sha256=$(shasum -a 256 "$output_ipa" | awk '{print $1}')
# Receipt binds this exact neutral archive to the verified stock input.
# Archive hashes vary across signing runs; filenames are not identity.
print -r -- "{\"baseline_sha256\":\"$actual_input_sha256\",\"neutral_sha256\":\"$output_sha256\"}" > "$output_ipa.neutral.json"
print "built pure signer-neutral IPA: $output_ipa"
print "input_sha256=$actual_input_sha256"
print "output_sha256=$output_sha256"
print 'bundle_identity=stock extensions=2 embedded_profile=absent signer_entitlements=absent injected_runtime=absent'
