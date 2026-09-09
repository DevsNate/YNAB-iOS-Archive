# Modification ledger

The initial tooling baseline contains no functional app patches. That commit prepares the exact stock IPA for later patching using ad-hoc signing and provisioning removal. Detailed verification belongs to YNAB-KB `Engineering-KB/docs/ios/stock-baseline.md`. Signing preparation does not establish device or capability parity.
## Working-tree functional patch

The server URL/login patch is isolated under `patches/server-url`. It changes
the build-735 native email validator to accept an origin, exposes validated
selection and saved-origin functions through a minimal bridge, and changes the
shared runtime login owner to use the selected origin with the separate local
protocol identity. Online WebView requests and account-controller navigation policies use the same
selected origin. No historical offline account-widget bridge is included.
Foundation tests, build/signing checks and user-operated online acceptance passed
on 2026-09-09. See `patches/server-url/README.md` and the Engineering KB
`ios/server-url-login` record. Offline behavior is excluded.
