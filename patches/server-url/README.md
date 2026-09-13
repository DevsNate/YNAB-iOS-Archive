# iOS server URL patch

This isolated patch supplies the URL/login endpoint contract for YNAB 26.32 build 735. `Endpoint.m` validates an HTTP(S) origin (optional port, no path/query/fragment/credentials), canonicalizes it, and persists only accepted values. `YNABSavedOrigin` is read during the existing shared-library initialization boundary; `YNABSelectOrigin` is called from the patched shared-runtime login owner and returns the canonical origin. The caller supplies `local@ynab5.invalid` separately as the protocol identity. Stock password, session, sync, database and calculation code remain untouched.

The patch is source-owned and does not include the historical client bridge.
The current working tree also adds the account-surface fallback described below.
The binary build step must retain exact build-735 occurrence guards before
applying native or shared-library substitutions. Keep external IPA and signed
output outside Git.

## Online WebView routing (2026-09-09)

The bridge rewrites HTTP(S) `app.ynab.com` requests at `WKWebView.loadRequest:`
using the saved origin. Method, body, headers, encoded path/query and fragment
are retained; stale Host is removed. File bootstrap URLs, native callback
schemes and other hosts remain unchanged. AccountWidgetViewController and
YBAccountSettingsViewController navigation delegates allow the exact selected
origin and otherwise retain their original policy. Stock-host navigation is
cancelled and reissued against the selected origin.

Build-735 IDA evidence: widget reload `0x100071f98` loads a bundle resource;
`0x1000770e4` constructs the subsequent account-widget request with native
headers. Policy `0x1000768b4` uses host/port comparator `0x100076708`, whose
stock origin is initialized at `0x100545aa8`. Settings policy is
`0x1003b45f8`. This is online routing only, not offline account functionality.

Foundation tests cover request preservation, external/native/file URL exclusion,
and scheme/port-aware origin checks. The patched IPA passed build and signature
checks on 2026-09-09. The user subsequently confirmed online login and the account
pages/Reflect work on Android and iOS. Exhaustive transport coverage is not claimed.

## Offline account surfaces (working tree, 2026-09-10)

Eligible account-widget and Account Settings loads probe the selected server's
`/health` endpoint. A transport failure loads the staged `YNABOffline` Web
assets through the existing WebKit controllers and stock callback handlers.
The fallback widget receives the actual iOS version so its captured stock
assets can identify the platform. Its offline-only transform selects the
captured stock iOS 26 style class for every iOS fallback, so provider cards,
form controls and bottom actions all use the same pill/grid radius tokens as
the online widget. Its provider projection uses the same alphabetical order as
the Server response.

The unlinked-account form stays stock. While offline, its validation and create
requests cross the scoped `AccountWidgetMessageHandler` bridge into the
version-guarded shared-library dispatcher. The new composite action delegates
creation to the stock account owner and optional loan-category pairing owner in
one outer change set. Before the optional pairing screen enables Skip, its
offline API branch projects the selected user's visible local categories in the
same grouped shape as the Server. The projection is read-only; account/category
mutation stays in the shared-library action. The
bridge writes no SQLite data; it reports success only after a read-only
current-user/current-budget lookup finds the account. Account
Settings uses the corresponding scoped WebKit handler for local identity and
First Name operations; identity is not exported into arbitrary JavaScriptCore
contexts.

An offline `sync:true` close still becomes `sync:false` to avoid a server task.
After durable offline account readback, or when an online widget requests its
normal `sync:true` close, the bridge marks native presentation invalidation as
pending. The stock widget dismissal consumes that marker only after the online
sync/close or offline save/close has finished. It then finds the existing stock
`AccountListViewController`, sets its runtime `needsReloadData` flag and invokes
its exposed `reloadDataIfNeeded` selector. This uses the stock local list reload
without performing a second write or replacing online server sync.

An online account widget also keeps a bounded liveness monitor on the selected
origin, probing `/health` every two seconds while visible. A transport failure
switches that WebView to the bundled offline document. Before a remote
`closeWidget(sync:true)` is forwarded, one final probe changes only a failed
transport close to `sync:false`, preventing the stock sync HUD from remaining
stuck on “Syncing”. App-wide startup/background synchronization is outside this
widget-scoped boundary.

The temporary routing/action trace and the loan-detail reload/global-
notification workaround were removed after the stock pending-calculation
lifecycle established the actual first-open loan owner. The remaining native
refresh hook is scoped to the account list after widget dismissal.

Source tests and a full Developer-signed package passed. User-operated radius
parity, online fresh-loan creation/refresh, fresh and corrected-old loan target
editing, offline checking, skipped-loan creation/refresh, paired offline loan
Create Target, restart durability and reconnect/no-duplicate sync all passed.
