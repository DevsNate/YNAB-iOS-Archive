#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}; root=${script_dir:h}; app=${1:-}
[[ -n "$app" && -d "$app" ]] || { print -u2 "usage: $0 extracted.app"; exit 64; }
source="$root/patches/offline-surfaces"
[[ -f "$source/account-widget/index.html" && -f "$source/account-settings/index.html" ]] || { print -u2 "offline source bundles missing"; exit 65; }
target="$app/YNABOffline"
mkdir -p "$target/account-widget" "$target/account-settings"
ditto "$source/account-widget" "$target/account-widget"
ditto "$source/account-settings" "$target/account-settings"
widget_chunk=$(rg -l --glob 'chunk.*.js' 'async createBudgetAccount' "$target/account-widget/assets/ynab_account_widget_mobile/assets" | head -n 1)
[[ -n "$widget_chunk" ]] || { print -u2 "offline widget account owner missing"; exit 65; }
node "$root/scripts/patch-offline-widget.mjs" "$widget_chunk"
[[ -f "$target/account-widget/index.html" && -f "$target/account-settings/index.html" ]] || exit 65
print "installed stock offline bundles into $target"
