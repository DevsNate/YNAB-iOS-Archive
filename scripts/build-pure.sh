#!/bin/zsh
set -euo pipefail

# Compatibility entry point only. The implementation is the V10 builder, not
# the retired zsign/ad-hoc "pure" pipeline that previously lived here.
script_dir=${0:A:h}
exec python3 "$script_dir/build-v10-signer-neutral.py" "$@"
