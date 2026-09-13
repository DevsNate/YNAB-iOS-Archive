# YNAB iOS baseline tooling

Stock YNAB 26.32 build 735 → signer-neutral IPA → future individual patches → final device signing.

## Requirements and build

macOS, zsh, Xcode command-line tools (`codesign`, `otool`, `plutil`), zsign, unzip, shasum and ripgrep. Supply the preserved decrypted IPA externally; the exact hash is in [baseline/manifest.json](baseline/manifest.json).

```sh
./scripts/build-pure.sh "$YNAB_IOS_BASELINE_IPA"
# Optional new external output path:
./scripts/build-pure.sh "$YNAB_IOS_BASELINE_IPA" "$YNAB_IOS_OUTPUT_IPA"
```

Default output is sibling `YNAB-Output/iOS/YNAB-26.32-pure-signer-neutral.ipa`. Existing output files are refused. The script uses zsign ad-hoc signing and provisioning removal; no certificate or profile is required. This output is not a device-installable acceptance build. Final signing requires appropriate external credentials and entitlements.

The script is adapted from YNAB5-iOS scripts/build-pure.sh. It preserves the original stock-neutral stage, reads the hash from the manifest, defaults output outside Git, refuses overwrites, and propagates entitlement-inspection failures. No functional patches or bridge injection are included.

## Build the server URL/login patch

Two stable scripts own the pipeline: build-pure.sh prepares stock once;
build-patch.sh consumes the neutral IPA and applies all current patches.
Future features extend this patch stage. Final device signing stays separate.

```sh
mkdir -p ../YNAB-Output/iOS/server-url-login
./scripts/build-pure.sh "$YNAB_IOS_BASELINE_IPA" ../YNAB-Output/iOS/server-url-login/neutral.ipa
./scripts/build-patch.sh ../YNAB-Output/iOS/server-url-login/neutral.ipa ../YNAB-Output/iOS/server-url-login/patched.ipa
```

The pure stage writes a .neutral.json receipt beside the verified neutral IPA.
The patch stage verifies its SHA-256 and stock baseline identity against this
receipt. Keep the receipt with the IPA; a renamed receipt can be passed as the
third argument. This is a local integrity check, not a signed attestation.
Filenames are not input identity. Use descriptive feature folders for outputs,
never commit hashes. Existing outputs are refused; use a new filename to rebuild.

The patch validates and persists the origin only when login is submitted,
restores it before cached-session login, and leaves password, session, sync,
database and calculation owners stock. It also installs the current offline
account surfaces. Their unlinked-account flow uses the captured stock form and
the stock shared-library account action; it does not write SQLite directly.
Build/sign success still requires device acceptance.

Detailed evidence and limitations live in sibling YNAB-KB at `Engineering-KB/docs/ios/stock-baseline.md` (or under `YNAB_KB_ROOT`). See [the modification ledger](docs/modification-ledger.md). Raw IPAs, extracted apps and signing material remain external.
