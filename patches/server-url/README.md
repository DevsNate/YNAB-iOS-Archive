# iOS server URL patch

This isolated patch supplies the URL/login endpoint contract for YNAB 26.32 build 735. `Endpoint.m` validates an HTTP(S) origin (optional port, no path/query/fragment/credentials), canonicalizes it, and persists only accepted values. `YNABSavedOrigin` is read during the existing shared-library initialization boundary; `YNABSelectOrigin` is called from the patched shared-runtime login owner and returns the canonical origin. The caller supplies `local@ynab5.invalid` separately as the protocol identity. Stock password, session, sync, database and calculation code remain untouched.

The patch is source-owned and does not include the historical client bridge or unrelated account/settings features. The binary build step must add exact build-735 occurrence guards before applying the native validator and login-owner substitutions. Keep external IPA and signed output outside Git.

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
