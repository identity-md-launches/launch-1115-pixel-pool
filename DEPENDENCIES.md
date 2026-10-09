# Vendored sources

These dependencies are supplied as ordinary source files; no install step or git submodule is required. Upstream files are unchanged. Source subsets include the files used by this project and upstream license notices.

| Directory | Upstream | Pinned revision | Usage |
| --- | --- | --- | --- |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Core interfaces/libraries and real test PoolManager; `src/` except upstream test helpers, plus licenses |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `0258fe875e1d8e207c1eb7175e542ea32356773c` | Test support, `src/` and licenses |
| `lib/solmate` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` | Core PoolManager's transitive `Owned` base in tests |

v4-core has per-file MIT and BUSL-1.1 licensing; see `lib/v4-core/licenses/`. Solmate is AGPL-3.0 and forge-std is Apache-2.0/MIT; their upstream notices are included. The project's own source files are MIT licensed. No v4-periphery, BaseHook, OpenZeppelin, or external rendering/encoding library is used by the hook.
