# YNAB iOS baseline tooling

The maintained baseline is stock decrypted YNAB 26.35 build 744 transformed
into a V10-style signer-neutral, unsigned/resign-required carrier. Functional
private-server behavior is a later and separate layer.

## Artifact boundaries

- **Stock decrypted input** — exact external IPA sealed by
  `baseline/manifest.json`.
- **Signer-neutral carrier** — stock product identity and resources, three
  version-verified App Group resolver patches, and no stale signing state.
- **Final signed artifact** — a derivative signed with the selected certificate,
  provisioning profile and common App Group entitlements.
- **Functional patch artifact** — a later derivative containing an explicitly
  scoped feature such as private-server URL selection.

Do not call the resign-required carrier installable, and do not treat signing
success as device acceptance.

## Build and verify 26.35

Requirements: macOS, Python 3, Xcode command-line tools, zsh and the exact
external IPA whose SHA-256 is recorded in `baseline/manifest.json`.

```sh
./scripts/build-v10-signer-neutral.py \
  /path/to/com_youneedabudget_evergreen_YNAB_Evergreen_26_35.ipa \
  /external/output/YNAB-26.35-V10-signer-neutral-resign-required.ipa

./scripts/verify-v10-signer-neutral.py \
  /path/to/com_youneedabudget_evergreen_YNAB_Evergreen_26_35.ipa \
  /external/output/YNAB-26.35-V10-signer-neutral-resign-required.ipa \
  --receipt /external/output/YNAB-26.35-V10-signer-neutral-resign-required.ipa.v10.json
```

`scripts/build-pure.sh` and `scripts/verify-pure.sh` are compatibility entry
points for those two V10 tools. They do not contain the retired zsign/ad-hoc
26.32 implementation.

The builder refuses a stock hash mismatch, a version/build mismatch, any
target binary hash/UUID/instruction mismatch, occupied code caves, unexpected
Mach-O counts, output paths inside the repository and overwrites. Generated
IPAs and receipts remain outside Git.

The independent verifier reconstructs the expected result from stock, checks
every non-signature file, all thin and universal Mach-O slices, UUIDs, dynamic
dependencies, the three runtime patches and resolver payloads, and confirms
the result remains unsigned.

## Runtime-neutral patch

The only runtime change is in the main executable and the two widget
executables. Each stock six-instruction sequence that materializes
`group.com.youneedabudget.evergreen.YNAB-Evergreen` is replaced with a call to
the resolver in `patches/signer-neutral/YNABAppGroupResolver.S` and five NOPs.
The following stock `mov x26, x0` and release remain unchanged.

The resolver dynamically loads Security.framework, reads the current process'
`com.apple.security.application-groups` entitlement, selects the
lexicographically smallest non-null group, and returns a retained CFString so
the stock release remains balanced. It returns nil when no group is available;
it never falls back to YNAB's unauthorized stock group.

No Keychain access-group rewrite is included. The 26.35 YNAB Keychain owner
does not supply `kSecAttrAccessGroup`; its service string is not a signer
identity. No server URL, endpoint routing, login bypass, offline widget,
subscription or feature patch is included.

## Packaging and final signing

The carrier removes all `_CodeSignature` directories and embedded profiles.
For every one of the 12 Mach-O slices it physically removes the EOF signature
payload, retains `LC_CODE_SIGNATURE` with `datasize = 0`, and corrects
`__LINKEDIT` accounting. The universal arm64/arm64e Swift compatibility dylib
is preserved as a universal binary.

The empty signature command is accepted by zsign-style signers, including the
class of workflow used by eSign/Feather. zsign reallocation and subsequent
deep signature verification pass. Apple's standalone `codesign` does not
allocate a fresh signature from this empty-command carrier and reports
`invalid or unsupported format for signature`; it is not the supported final
signer for this stage.

The final signing entitlements must make the same App Group sort first in the
main app, YNABWidgetExtension and YNABWidgetIntentHandler. Supplying merely one
common group is insufficient if another process has an earlier-sorting group,
because each process resolves its own entitlement array independently. APNs,
Sign in with Apple, FinanceKit, associated domains and other Apple-controlled
capabilities remain dependent on the final profile.

## Updating to a later YNAB version

A new IPA is not an automatic builder input. Before admitting a version:

1. hash and inventory the stock IPA, bundles, architectures and encryption;
2. compare entitlements and signer-bound runtime identities with the last
   accepted version;
3. independently locate App Group and any explicit Keychain owners;
4. confirm decisive xrefs and instructions in IDA/disassembly;
5. select and verify executable caves and every imported stub used by the
   resolver;
6. update all version-specific hashes, UUIDs, bytes and addresses;
7. build twice and require byte-for-byte deterministic output;
8. run the independent verifier plus wrong-input and overwrite tests;
9. exercise the supported final signer and deep signature verification; and
10. perform bounded device launch, persistence and widget shared-state tests.

If the new binary layout or ownership differs, redesign the patch instead of
forcing the old workflow through new bytes. Record the evidence and limits in
the Engineering KB before declaring the version accepted.

## Legacy 26.32 patch scripts

`scripts/build-patch.sh` and the existing server URL, offline-widget,
plan-bootstrap and category-pin transforms document the older build-735 work.
They are not part of the 26.35 neutral carrier and must not be run against it
without a separate version-specific port and review.
