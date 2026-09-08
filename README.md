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

Detailed evidence and limitations live in sibling YNAB-KB at `Engineering-KB/docs/ios/stock-baseline.md` (or under `YNAB_KB_ROOT`). See [the modification ledger](docs/modification-ledger.md). Raw IPAs, extracted apps and signing material remain external.
