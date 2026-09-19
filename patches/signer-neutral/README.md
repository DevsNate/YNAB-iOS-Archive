# YNAB 26.35 signer-neutral resolver

`YNABAppGroupResolver.S` is version-locked to stock YNAB 26.35 build 744.
The maintained builder compiles it as arm64 assembly, extracts the relocation-
free `__TEXT,__text` payload, replaces its guarded branch markers and injects
one copy into an existing executable cave in each direct App Group owner.

| Owner | Stock function | Patched VM | Resolver VM | dlopen stub | dlsym stub |
| --- | ---: | ---: | ---: | ---: | ---: |
| Main app | `0x100262744` | `0x100262900` | `0x1019b00a0` | `0x101445a9c` | `0x101445aa8` |
| Widget | `0x100005acc` | `0x100005c88` | `0x10033c088` | `0x1002ad744` | `0x1002ad750` |
| Widget intent | `0x1000057d4` | `0x100005990` | `0x100196210` | `0x10015f318` | `0x10015f324` |

Each function contains the same stock shared-container path and exactly one
reference to the stock App Group literal. The patch replaces the 24-byte
literal materialization/Swift bridge sequence with `BL resolver` plus five
NOPs. It deliberately leaves the following `mov x26, x0`, container lookup and
`objc_release_x26` unchanged.

The resolver returns a +1 CFString on success because the stock caller releases
that value. It passes `NULL` as the required allocator argument to
`SecTaskCreateFromSelf`, releases its temporary CoreFoundation objects, and
returns nil when it cannot obtain a usable current-signer App Group.

Do not reuse these addresses for another app version. Follow the update audit
in the repository README, then record a new version-specific map and guards.
