# PIXEL POOL test coverage

Run `forge build` and `forge test`. No RPC, environment values, new dependencies, or
configuration changes are required. To keep generated artifacts inside the test
directory, append `--out test/scratch/out --cache-path test/scratch/cache`.

The pre-existing tests cover deployment permissions, mined PIXEL > IMD addresses,
the opening price, all callbacks, second-pool rejection, quote-side selection,
shade thresholds, events, native quotes, sequential painting, and the full-canvas
render budget. The additions exercise these independent properties:

| File | Property and campaign |
| --- | --- |
| `PixelPoolTokenInvariant.t.sol` | Four actors, 256 sequences of 96 actions. Fixed supply equals summed balances; every balance and allowance matches a model of successful transfers and approvals. Failed transfers preserve allowances. Includes zero, entire-balance, excessive, and maximum amounts, self-transfers, approval replacement/revocation, and infinite allowances. |
| `PixelPoolSequence.t.sol` | Both IMD address orders, each with 128 sequences of 64 actions. A real v4 PoolManager runs a hooked pool beside an independently initialized pool without a hook. Swap deltas, liquidity deltas, prices, fee growth, and LP fees must match. The canvas model changes only after successful swaps, and the hook must accrue no tokens, ETH, claims, or transient deltas. |
| `CanvasRoundTrip.t.sol` | Decodes SVG paths back into all 1024 pixels, checking palette, unique coordinates, gaps, bounds, and footer. Covers randomized images, every uniform palette, empty images, large counters, and base64 output. |

The pool sequences begin at stroke 1020 using real swaps, so short random sequences
cross a pass boundary. A deterministic 2050-swap regression crosses two boundaries
and compares the complete canvas throughout. Successful trades include exact input,
exact output, all shade boundaries, and price-limited partial fills. Other actions
change liquidity, deliberately fail settlement, or attempt unauthorized/wrong-pool
callbacks. Expected failures are asserted explicitly; unexpected handler reverts
fail the invariant campaign. Only action selectors are targeted.

IMD is an offline 18-decimal token model at the specified address. These tests exercise
the vendored PoolManager implementation without a fork; they do not establish the
behavior of live IMD bytecode or a live launch factory. The deterministic deployment
test in the existing suite checks the specified opening price; the differential
sequence pools start at 1:1 to exercise both quote orders under comparable conditions.

No implementation defects were reproduced by these tests.
