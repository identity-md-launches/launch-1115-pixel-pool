# PIXEL POOL

An immutable Uniswap v4 hook that paints a 32×32 canvas, one dot for each completed swap. The accompanying ERC-20 is **Pixel Pool (PIXEL)**: 18 decimals, exactly **1,000,000,000 tokens**, all minted to its deployer. Neither contract has an owner, minting privilege, pause, upgrade, fee setting, or rescue function.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 tools/check_manifest.py
```

Foundry pins Solidity **0.8.26**, optimizer 200 runs, Cancun, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`; there are no submodules, package downloads, FFI, RPC calls, environment-variable reads, or filesystem permissions in the tests. A verifier with the pinned compiler installed can build and test without network access.

The hook imports only v4-core and the project's own SVG library. Tests use a real v4 PoolManager, its transitive Solmate `Owned` dependency, and forge-std. Exact upstream revisions and licenses are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).

## Canvas behavior

`PixelPoolHook(IPoolManager)` implements `IHooks` directly. Its constructor validates that its address advertises **beforeInitialize** and **afterSwap** only: low 14 bits **0x2040 (8256)**. Every callback checks the immutable manager address. Disabled callbacks reject manager calls with `HookNotEnabled` and other callers with `NotPoolManager`.

The first successful `beforeInitialize` records the entire PoolKey's hash. Further initialization calls revert `PoolAlreadySet`; `afterSwap` rejects any other PoolKey with `WrongPool`. Initialization that subsequently fails inside the manager also rolls back this lock.

Initialization sets `quoteIsCurrency0` when currency0 is the specified IMD address or native ETH. Otherwise the quote is currency1. The launch uses IMD; native ETH is supported by the specified detection rule, with the same thresholds in 18-decimal native units. Other quote currencies are outside the launch assumptions. The hook does not impose additional token, fee, or spacing restrictions on the first pool.

Each `afterSwap` increments `strokes`, then writes `(strokes - 1) % 1024`. Index `y * 32 + x` is dot `(x, y)`, starting at the top left. Thirty-two indexes fit in each `uint256`, with the first index in the least significant byte. There are exactly 32 such storage words. A new pass overwrites dots individually; untouched dots keep the previous pass's colors. `pass()` is 1 when empty and after swaps 1–1024, then 2 for swaps 1025–2048.

Buy means `zeroForOne == quoteIsCurrency0`. Shade uses the magnitude of the **executed quote-side BalanceDelta**, including the LP fee in quote input, rather than `amountSpecified` or the launch-token amount. This handles both exact input and exact output and partial fills. Signed amounts are widened before negation to handle `int128.min` safely.

| Quote amount (18 decimals) | Buy index / color | Sell index / color |
| --- | --- | --- |
| less than 5 | 1 / `#1f7a3d` | 5 / `#7a1f1f` |
| 5 to less than 50 | 2 / `#22b455` | 6 / `#c42b2b` |
| 50 to less than 500 | 3 / `#2ee66b` | 7 / `#ff3b3b` |
| 500 or more | 4 / `#8dffad` | 8 / `#ff9a9a` |

Empty index 0 is `#0b0b12`. Any successful swap callback, including one with zero executed quote, paints a dot; no minimum trading size or identity gate is added. `Painted(stroke, pixel, color, painter)` indexes the first, second and fourth arguments. `painter = tx.origin` is display attribution only. With relayers or account abstraction it can identify a relayer/bundler rather than the trader. It never authorizes an action.

`pixelAt(i)` accepts 0–1023; `canvas()` returns 1024 bytes; `palette(i)` accepts 0–8 and returns a `bytes7` hex color. `render()` returns a complete SVG with viewBox `0 0 32 36`, a dark background, nine color paths (including empty), 0.8-unit squares at 0.1-unit offsets, and the footer `PIXEL POOL  pass N  swaps M`. It allocates one 32,768-byte buffer, appends into it, then truncates its length. `renderURI()` returns standard padded Base64 with the `data:image/svg+xml;base64,` prefix.

## Launch parameters and address mining

[launch.json](launch.json) contains single values for the admission manifest:

| Parameter | Value |
| --- | --- |
| Kind | `univ4_hook` |
| Hook contract | `PixelPoolHook` |
| Constructor | `["$poolManager"]` |
| Permissions | `["beforeInitialize", "afterSwap"]` |
| Token contract | `PixelPoolToken` (no constructor arguments) |
| Paired currency / currency0 | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD) |
| Currency1 | Newly deployed PIXEL, numerically **greater than IMD** |
| Pool fee | `12500` (1.25%, the launchpad's standard fee) |
| Tick spacing | `60` |
| Initial sqrtPriceX96 | `50108289675009586237282760313921` |

The initial currency1/currency0 ratio is 400,000 PIXEL per IMD. With 1 billion PIXEL this is the requested 2,500 IMD opening market cap. The hook adds no fees and never overrides the pool fee. Fee collection and distribution belong to the launchpad's standard infrastructure; the hook has no recipient or fee-accounting code.

CREATE2 addresses depend on the actual deploying factory, salt and exact creation bytecode; the hook's bytecode also includes its manager constructor argument. **There is no chain-independent token salt that can establish the required address order for an unspecified factory.** The supplied [PlanDeployment](script/PlanDeployment.s.sol) mines both salts from explicit deployment arguments. `$poolManager` is supplied by the launch system, never hardcoded. The factory address is the actual contract executing CREATE2, which the launch system also knows. No owner or user key is required to plan.

Run the following locally, substituting the launch system's real factory and manager addresses as arguments:

```text
forge script script/PlanDeployment.s.sol:PlanDeployment --sig 'run(address,address)' FACTORY_ADDRESS POOL_MANAGER_ADDRESS
```

This pure planner does not broadcast or read environment variables. It returns `(tokenSalt, token, hookSalt, hook)` and searches from salt 0 until the token sorts above IMD and the hook has exactly the required flags. The search limits fail with `SaltNotFound` rather than emit an invalid plan. Zero addresses fail with `MissingDeploymentArgument`. Salts are raw bytes32 CREATE2 salts: if a factory derives its final salt from another value, its integration must use that derivation when planning. Recompute after changing factory, manager, compiler configuration, or source bytes.

The deployer must feed the mined salts into the launch factory's deployment operation, verify the predicted addresses are unused, and deploy PIXEL, deploy the hook, and initialize **in one transaction**, with IMD as currency0. Abort if the computed PIXEL address is not greater than IMD; do not silently invert the price. The test `test_plannedDeploymentCreatesPixelAboveImdAtOpeningPrice` calls this exact planner, deploys both contracts with its salts from a local factory, asserts both predicted addresses and `PIXEL > IMD`, opens the pool at the manifest price and fee, and executes both a buy and a sell.

The only-pool rule deliberately binds the **first** initialization, without authenticating its `sender` as a particular factory. Separating hook deployment from initialization lets another transaction claim that hook for another pool. Atomic launch is therefore an operational requirement. The enabled initialization callback also prevents successful initialization at a predicted hook address before code is deployed.

## Validation and operational responsibilities

The tests cover sequential painting and slot boundaries, wraparound, both quote orders and trade directions, exact input/output, threshold boundaries, partial fills, native quote detection, signed extremes, unauthorized and disabled callbacks, permission-address rejection, single-pool binding, transaction rollback, attribution, full-canvas rendering, and Base64 parity with Foundry's independent encoder. Token tests cover supply conservation, transfer events, allowances, failure rollback and absent mint/admin/upgrade selectors. Runtime opcode scans reject delegation, destruction and, for the hook, any external calls.

A fully painted canvas containing all eight trading colors rendered in **4,524,635 gas** locally with cold hook storage, versus the 15,000,000 limit. The gas assertion remains in the suite. Painting requires no rendering and makes no external calls. The manager and router settle the original swap without hook deltas or ERC-6909 claims. Reverting settlement rolls back the paint.

Security review against the supplied references found no hook fund-handling path, return-delta permission, external-call reentrancy surface, admin role or unbounded callback loop. Rendering loops are bounded by 9 × 1024 and token transfers make no external calls. The specified IMD address is taken from the brief; its deployed code and behavior were not verified on a production chain. Local IMD behavior is modeled as a standard 18-decimal ERC-20. No fork test, Slither, Mythril, independent audit, or production transaction was run.

Before launch the network deployer supplies the correct chain's manager, verifies IMD and Cancun support, mines/rechecks salts, simulates the atomic launch with actual factory liquidity and fee infrastructure, and arranges independent review. Liquidity allocation, LP ownership and launchpad fee distribution remain the launchpad's responsibility. This project introduces no alternate liquidity policy. Source verification and monitoring the `Painted` events are deployment operations.

After launch there are **no hook settings or required maintenance calls**. Swaps paint automatically and views render automatically. Direct ETH payments are rejected; unsolicited tokens sent to the hook have no recovery path. There is no wallet control, transaction broadcast, or deployed address claimed by this deliverable.
