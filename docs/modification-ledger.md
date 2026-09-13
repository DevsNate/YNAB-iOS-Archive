# Modification ledger

The initial tooling baseline contains no functional app patches. That commit prepares the exact stock IPA for later patching using ad-hoc signing and provisioning removal. Detailed verification belongs to YNAB-KB `Engineering-KB/docs/ios/stock-baseline.md`. Signing preparation does not establish device or capability parity.
## Working-tree functional patch

The server URL/login patch is isolated under `patches/server-url`. It changes
the build-735 native email validator to accept an origin, exposes validated
selection and saved-origin functions through a minimal bridge, and changes the
shared runtime login owner to use the selected origin with the separate local
protocol identity. Online WebView requests and account-controller navigation
policies use the same selected origin. The working tree also includes selected-
server-failure fallbacks for the existing account widget and settings WebViews.
Foundation tests, build/signing checks and user-operated online acceptance passed
on 2026-09-09. The offline widget supplies the actual iOS WebView OS version,
uses server-equivalent provider ordering, and routes unlinked-account validation
and creation through the native callback handler to a version-guarded stock
shared-library action. That action composes the stock account creation and loan
category-pairing owners in one outer change set. The offline loan path projects
the selected user's visible local categories in the grouped envelope consumed
by the captured widget; the projection is read-only. Success is returned to the
widget only after a current-user/current-budget read-only SQLite lookup finds
the persisted account. The offline-only widget transform selects the stock iOS
26 style class across the complete widget, including its bottom actions. After
verified offline creation or a normal online `sync:true` close, widget dismissal
invalidates the stock native account list through its
`needsReloadData`/`reloadDataIfNeeded` presentation path. Source tests and a
Developer-signed package passed; visual radius parity, offline creation,
immediate list refresh, paired-loan Create Target, restart durability,
reconnect sync and no-duplicate behavior all passed user-operated device
acceptance. On 2026-09-12 the user also confirmed immediate refresh for a fresh
online loan, offline checking and an offline loan using Skip; Create Target
opened for both a fresh online loan and a previously crashing synced loan. The
offline provider-card disabled state retains the captured image colors and
applies the existing 50% opacity plus pointer/keyboard blocking; it no longer
applies a grayscale filter. The replacement
`offline-provider-color-fade-19-developer-api-ditto.ipa` is source-verified,
deep-signature-verified and installed successfully on the paired iPhone;
the user confirmed offline provider cards retain their colors rather than
appearing black-and-white. See
`patches/server-url/README.md` and the Engineering KB iOS records.

The current source follow-up adds a selected-server liveness monitor for an
already-open remote account widget. It probes `/health` every two seconds and
loads the existing bundled fallback when the server disappears. A final probe
guards remote `sync:true` close messages and changes only a failed transport
close to `sync:false`, so the stock account-widget sync HUD cannot remain stuck
on “Syncing”. The app-wide startup/background sync lifecycle is intentionally
not changed. Source tests, arm64 syntax, neutral patch packaging, explicit
nested Developer signing, packaged deep-signature verification and in-place
CoreDevice installation passed for `open-widget-server-loss-20-developer-api.ipa`;
the user-operated mid-widget network-loss transition and prompt close also pass.
