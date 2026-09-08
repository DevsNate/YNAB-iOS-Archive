# YNAB iOS repository rules

Preserve unrelated changes. Keep private inputs, credentials, signing material and generated artifacts outside Git. Use portable paths. Inspect repository status, branch and remotes before editing.

The sealed stock input is defined by `baseline/manifest.json`. Reuse `scripts/build-pure.sh` for stock-to-signer-neutral preparation; do not replace it with a new pipeline or import legacy functional patches without task-specific review. Preserve the baseline commit and keep each coherent functional change separately reviewable.

## Knowledge base integration

Locate `YNAB-KB` via `YNAB_KB_ROOT` when set, otherwise sibling `../YNAB-KB` resolved from this repository root. The intended identity is `DevsNate/YNAB-KB`; do not substitute a legacy KB.

Read its `AGENTS.md` for the shared task contract, authorization, tool use, completion and documentation rules. Follow `Engineering-KB/docs/ios/workflow.md` and the relevant feature/patch pages and prerequisites. Validate documentation against actual source and state.

The implementing chat owns the associated KB updates and may edit the sibling checkout. Keep local executable build/usage contracts here; maintain Engineering evidence and System explanations through the KB rules. If the KB is inaccessible, continue independent safe work, preserve a concise pending documentation handoff locally, and report the gap. Do not claim the KB is current.
