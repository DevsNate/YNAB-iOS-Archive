#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h}; stage=$(mktemp -d /tmp/ynab-ios-assets.XXXXXX); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Test.app"
zsh "$root/scripts/install-offline-assets.sh" "$stage/Test.app"
[[ -f "$stage/Test.app/YNABOffline/account-widget/index.html" ]]
[[ -f "$stage/Test.app/YNABOffline/account-settings/index.html" ]]
widget="$stage/Test.app/YNABOffline/account-widget"
grep -Fq 'DEVICE_OS_VERSION: iOSVersion' "$widget/index.html"
grep -Fq 'ynabCreateOfflineAccount' "$widget/index.html"
grep -Fq 'ynabValidateOfflineAccount' "$widget/index.html"
grep -Fq 'ynabReadOfflinePairingCategories' "$widget/index.html"
grep -Fq 'body[data-offline="true"] .account-widget-api-popular-list button' "$widget/assets/provider_cards/provider-cards.css"
grep -Fq 'opacity: 0.5' "$widget/assets/provider_cards/provider-cards.css"
grep -Fq 'pointer-events: none' "$widget/assets/provider_cards/provider-cards.css"
! grep -Fq 'grayscale' "$widget/assets/provider_cards/provider-cards.css"
! grep -Fq 'border-radius: 2.375rem' "$widget/assets/provider_cards/provider-cards.css"
grep -Fq -- '--accountWidgetButtonRadius:0.5rem' "$widget/assets/ynab_account_widget_mobile/assets/ynab-account-widget-mobile.8ad957f255ea1eccc4b739c830656436.css"
grep -Fq -- '--accountWidgetButtonRadius:1.5rem' "$widget/assets/ynab_account_widget_mobile/assets/ynab-account-widget-mobile.8ad957f255ea1eccc4b739c830656436.css"
grep -Fq -- '--accountWidgetGridItemRadius:2.375rem' "$widget/assets/ynab_account_widget_mobile/assets/ynab-account-widget-mobile.8ad957f255ea1eccc4b739c830656436.css"
grep -Fq -- '--accountWidgetInputRadius:0.5rem' "$widget/assets/ynab_account_widget_mobile/assets/ynab-account-widget-mobile.8ad957f255ea1eccc4b739c830656436.css"
grep -Fq -- '--accountWidgetInputRadius:1.5rem' "$widget/assets/ynab_account_widget_mobile/assets/ynab-account-widget-mobile.8ad957f255ea1eccc4b739c830656436.css"
! grep -R -Fq 'Connect to Wi-Fi or cellular to configure a provider.' "$widget"
chunk=$(rg -l --glob 'chunk.*.js' 'offlineAccountValidationError' "$widget/assets/ynab_account_widget_mobile/assets" | head -n 1)
[[ -n "$chunk" ]]
node "$root/scripts/tests/offline-widget.mjs" "$root/patches/offline-surfaces/account-widget/assets/ynab_account_widget_mobile/assets/chunk.5ef61e4716cab7872863.js"
print 'offline asset installation contract passed'
