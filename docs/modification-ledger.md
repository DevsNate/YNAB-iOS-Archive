# Modification ledger

## V10-style signer-neutral baseline — YNAB 26.35 build 744

The current baseline is derived from the sealed stock IPA with SHA-256
`f6aff1df27ce87c21c60b16133c5be958ab3c20ec6c1a2be3be212064a4d1bde`.
It preserves the stock main and extension bundle identifiers and changes only
the three independently verified runtime App Group owners: the main app,
YNABWidgetExtension and YNABWidgetIntentHandler.

Each owner calls a 750-byte, relocation-free resolver injected into a verified
zero-filled executable cave. The resolver loads Security.framework, reads the
current process' signed App Group entitlement, selects the lexicographically
smallest non-null value and returns it with +1 ownership to balance the stock
caller release. It fails closed when no group is available. No explicit
Keychain access-group owner exists in the audited YNAB wrapper, so no Keychain
patch is included.

The packaging stage removes ten `_CodeSignature` directories and strips the
EOF signature payload from all 12 Mach-O slices while retaining empty
`LC_CODE_SIGNATURE` commands and correcting `__LINKEDIT`. The arm64/arm64e
universal Swift compatibility dylib remains universal. Non-Mach-O resources,
bundle metadata, UUIDs and load dependencies remain stock.

Two builds are byte-for-byte identical at SHA-256
`4560b55327fad975cfa03f3803eecaa855c99ee4a0883a2a2ed26ce58c3e9df7`.
The independent verifier, wrong-input rejection and overwrite rejection pass.
zsign successfully reallocates all signatures and the signed result passes
deep signature verification. A real Developer certificate/profile signing pass
also reallocates every signature, preserves the stock bundle identifiers,
applies the same five profile App Groups to the app and both extensions, and
passes deep/strict verification. That stock-ID/profile-entitlement shape
matches the previously device-accepted 26.32 signing convention. The resulting
26.35 derivative has SHA-256
`d390ae644c69dc945bc2334ab5c9c8dd8c08c94fdebf86809a7c4371765b843c`;
it installed in place on the connected iPhone as YNAB 26.35 build 744 under
the stock bundle identifier. The user then confirmed that the app launches,
sign-in succeeds, the widget works, and notification authorization presents
the expected prompt. Session persistence after force-quit and a concrete widget
action also pass. The 26.35 signer-neutral baseline is therefore device-
accepted for this bounded launch/session/widget scope. See
`patches/signer-neutral/README.md` and the Engineering KB iOS baseline record.

## Historical 26.32 build-735 work

Everything below this heading describes the older 26.32 functional patch
series. It is preserved as evidence but is not included in, or automatically
portable to, the 26.35 signer-neutral carrier.

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

## Local plan bootstrap parity — 2026-09-13

The Stock shared runtime defaults four local plan-creation owners to the legacy
`FTUE` category template: `customizeBudgetForNewUser`, `createNewBudget`,
`createNewBudgetInternal`, and the budget-editor creation path. The current
Server creates new plans with the emoji starter categories and their goal
metadata, `historical_setup`, and no pre-completed onboarding events. The
resulting state mismatch can make the Stock onboarding, Add Account and Ready
to Assign cards progress differently depending on where a plan was created.

`scripts/patch-plan-bootstrap.mjs` changes those four defaults to the existing
`NoCategoriesWizard` template. `scripts/build-patch.sh` runs the guarded
transform on the temporary IPA app bundle after offline assets are installed;
the sealed baseline and neutral input remain untouched. Every replacement must
match exactly once, so a version mismatch or already-patched bundle fails the
build. No native card-rendering rule is changed: iOS continues to consume the
shared onboarding and budget state through its Stock UI owners.

The focused source test, `git diff --check`, neutral build, patched package
pipeline and packaged-marker inspection pass. The candidate was explicitly
signed with the accepted `iPhone Developer: Created via API (5FAVWK45W6)`
identity across nested frameworks, dylibs, extensions and the main app; deep
signature verification passed. The external artifact is
`YNAB-Output/iOS/plan-bootstrap-parity-20260913/plan-bootstrap-parity-developer.ipa`
(SHA-256 `cc5594d454079d328a6efdc3ceac125165160904b04164d43f4e605452580649`).
CoreDevice installed it in place over the existing bundle identifier without
uninstalling or clearing app data. Fresh-plan device acceptance passes on both
clients for the starter categories and native welcome, Add Account and Ready to
Assign card progression. See the Engineering KB iOS plan-bootstrap record.

## Category pin and Current Goal sync follow-up — 2026-09-13

The Server revision `4d9b473` already persists and projects `pinned_index` and
`pinned_goal_index`, enforces one Current Goal per plan and replays category rows
on an empty refresh. The Stock shared-library reconciler otherwise preserves the
local pin values, so changes made by the other client do not converge.

`scripts/patch-category-pins.mjs` changes that one mapper on the temporary
patched IPA bundle. The sealed input and signer-neutral IPA remain unchanged and
the transform fails closed on a missing, duplicated or already-patched owner.
The focused transform and plan-bootstrap tests, shell checks, diff check and
staged marker simulation, patched signer-neutral IPA packaging and nested
signature verification pass. The final IPA was explicitly Developer-signed,
passed deep signature verification and was installed in place through
CoreDevice; SHA-256 is
`2dcd320b43dc8437438359f7c2f1e6bd3aa29a96d2f76b84b1509b8a3b63c3a1`.
User-operated tests confirmed pinned category and Current Goal convergence in
both directions between iOS and Android, and both values survived restarting
both apps. Offline tests also confirmed additive merging of distinct category
pins, propagation of an offline iOS unpin after reconnection, and convergence
of different offline Current Goal selections. Android's goal won the observed
conflict because of that run's sync order; no platform priority is guaranteed.
This feature boundary is device-accepted.
