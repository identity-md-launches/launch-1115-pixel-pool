// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PixelPoolHook} from "src/PixelPoolHook.sol";
import {PixelPoolToken} from "src/PixelPoolToken.sol";
import {PlanDeployment} from "script/PlanDeployment.s.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolActions} from "./helpers/PoolActions.sol";

/// @dev Runs each successful operation against two independently accounted v4 pools with identical terms.
/// The control pool has no hook. No state is copied between pools after initialization.
contract PixelPoolSequenceHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 constant ONE = 79228162514264337593543950336;
    IPoolManager public manager;
    PixelPoolHook public hook;
    PixelPoolToken public token;
    PixelPoolToken public quote;
    PoolActions public router;
    PoolKey internal key;
    PoolKey internal control;
    bool public immutable quote0;
    bytes internal expectedCanvas;
    uint256 public successfulSwaps;
    uint256 public nextPixel;
    uint256 public expectedPass = 1;
    uint256 public extraLiquidity;
    uint256 public rejectedSwaps;

    constructor(bool quoteIs0) {
        quote0 = quoteIs0;
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolActions(manager);
        // Offline model of the external 18-decimal IMD token; PIXEL itself is genuinely CREATE2-deployed.
        vm.etch(IMD, address(new PixelPoolToken()).code);
        quote = PixelPoolToken(IMD);
        deal(IMD, address(this), 1_000_000_000 ether);
        LaunchFixture factory = new LaunchFixture();
        PlanDeployment planner = new PlanDeployment();
        bytes32 tokenHash = keccak256(type(PixelPoolToken).creationCode);
        uint256 salt;
        while ((planner.predict(address(factory), bytes32(salt), tokenHash) > IMD) != quoteIs0) ++salt;
        token = factory.deployToken(bytes32(salt));
        assertEq(address(token) > IMD, quoteIs0);
        (bytes32 hookSalt,) = planner.mineHook(address(factory), manager);
        hook = factory.deployHook(manager, hookSalt);
        key = quoteIs0
            ? PoolKey(Currency.wrap(IMD), Currency.wrap(address(token)), 12500, 60, hook)
            : PoolKey(Currency.wrap(address(token)), Currency.wrap(IMD), 12500, 60, hook);
        control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(key, ONE);
        manager.initialize(control, ONE);
        assertEq(hook.quoteIsCurrency0(), quoteIs0);
        token.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, bytes32(0));
        router.liquidity(key, lp);
        router.liquidity(control, lp);
        expectedCanvas = new bytes(1024);
    }

    function trade(bool buy, bool exactInput, uint256 seed, bool partialFill) public {
        SwapParams memory params = _swapParams(buy, exactInput, seed, partialFill);
        BalanceDelta delta = _executeAndCompare(params, seed);
        _remember(buy, delta);
    }

    function _swapParams(bool buy, bool exactInput, uint256 seed, bool partialFill)
        private
        view
        returns (SwapParams memory)
    {
        uint256 amount = bound(seed, 1, 1000 ether);
        // Pin thresholds as well as sampling intermediate amounts.
        uint256[8] memory edges =
            [uint256(1), 5 ether - 1, 5 ether, 50 ether - 1, 50 ether, 500 ether - 1, 500 ether, 1000 ether];
        if (seed % 2 == 0) amount = edges[(seed / 2) % edges.length];
        bool zeroForOne = buy == quote0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (partialFill) {
            (uint160 price,,,) = manager.getSlot0(key.toId());
            limit = zeroForOne ? price - price / 1_000_000 : price + price / 1_000_000;
        }
        return SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit);
    }

    function _executeAndCompare(SwapParams memory params, uint256 seed) private returns (BalanceDelta delta) {
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        delta = router.swap(key, params, abi.encode(seed));
        int128 quoteDelta = quote0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = quote0 ? delta.amount1() : delta.amount0();
        assertEq(int256(quote.balanceOf(address(this))) - int256(quoteBefore), int256(quoteDelta));
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), int256(tokenDelta));
        BalanceDelta plain = router.swap(control, params, "");
        assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(plain), "hook changed trade economics");
    }

    function _remember(bool buy, BalanceDelta delta) private {
        int128 quoteDelta = quote0 ? delta.amount0() : delta.amount1();
        uint256 magnitude = uint256(quoteDelta < 0 ? -int256(quoteDelta) : int256(quoteDelta));
        uint8 color = buy ? 1 : 5;
        // An independent threshold-counting oracle, using the executed quote delta.
        if (magnitude >= 5 ether) ++color;
        if (magnitude >= 50 ether) ++color;
        if (magnitude >= 500 ether) ++color;
        if (nextPixel == 1024) {
            nextPixel = 0;
            ++expectedPass;
        }
        expectedCanvas[nextPixel] = bytes1(color);
        assertEq(hook.pixelAt(nextPixel), color);
        ++nextPixel;
        ++successfulSwaps;
    }

    function changeLiquidity(bool remove, uint256 seed) external {
        uint256 amount = bound(seed, 0, remove ? extraLiquidity : 1000 ether);
        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams(-887220, 887220, remove ? -int256(amount) : int256(amount), bytes32(0));
        BalanceDelta hooked = router.liquidity(key, lp);
        BalanceDelta plain = router.liquidity(control, lp);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "hook changed LP accounting");
        if (remove) extraLiquidity -= amount;
        else extraLiquidity += amount;
    }

    function failSettlement(bool buy) external {
        PixelPoolToken input = buy ? quote : token;
        input.approve(address(router), 0);
        bool zeroForOne = buy == quote0;
        SwapParams memory params =
            SwapParams(zeroForOne, -1 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        vm.expectRevert(PixelPoolToken.InsufficientAllowance.selector);
        router.swap(key, params, "");
        input.approve(address(router), type(uint256).max);
        ++rejectedSwaps;
    }

    function rejectForeignCallback(uint24 feeSeed, bool spoofManager) external {
        PoolKey memory wrong = key;
        wrong.fee = feeSeed == key.fee ? key.fee + 1 : feeSeed;
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        if (spoofManager) vm.prank(address(manager));
        vm.expectRevert(spoofManager ? PixelPoolHook.WrongPool.selector : PixelPoolHook.NotPoolManager.selector);
        hook.afterSwap(address(router), wrong, params, toBalanceDelta(-1 ether, 1 ether), "");
    }

    function assertState() public view {
        assertEq(hook.strokes(), successfulSwaps, "only successful swaps paint");
        assertEq(hook.pass(), expectedPass);
        assertEq(hook.canvas(), expectedCanvas, "a swap corrupted an earlier or neighboring pixel");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.quoteIsCurrency0(), quote0);
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 plainPrice, int24 plainTick, uint24 plainProtocolFee, uint24 plainLpFee) =
            manager.getSlot0(control.toId());
        assertEq(price, plainPrice);
        assertEq(tick, plainTick);
        assertEq(protocolFee, plainProtocolFee);
        assertEq(lpFee, plainLpFee);
        assertEq(lpFee, 12500);
        assertEq(manager.getLiquidity(key.toId()), manager.getLiquidity(control.toId()));
        (uint256 f0, uint256 f1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 plainF0, uint256 plainF1) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(f0, plainF0);
        assertEq(f1, plainF1);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(quote.balanceOf(address(this)) + quote.balanceOf(address(manager)), quote.totalSupply());
    }
}

abstract contract PixelPoolSequenceBase is Test {
    PixelPoolSequenceHandler internal handler;

    function _setup(bool quote0) internal {
        handler = new PixelPoolSequenceHandler(quote0);
        // Reach a pass boundary through genuine swaps, without directly editing hook storage.
        for (uint256 i; i < 1020; ++i) {
            handler.trade(i % 2 == 0, true, 1 ether, false);
        }
        handler.assertState();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.changeLiquidity.selector;
        selectors[2] = handler.failSettlement.selector;
        selectors[3] = handler.rejectForeignCallback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_canvasAndAccountingMatchIndependentModels() public view {
        handler.assertState();
    }

    function test_twoWrapsPreserveEveryOtherByteAndTradingEconomics() public {
        for (uint256 i; i < 1030; ++i) {
            handler.trade(i % 2 == 0, i % 3 == 0, (i + 1) * 1 ether, i % 7 == 0);
            if (i % 32 == 0) handler.assertState();
        }
        handler.failSettlement(true);
        handler.failSettlement(false);
        handler.changeLiquidity(false, 500 ether);
        handler.changeLiquidity(true, 500 ether);
        handler.assertState();
        assertEq(handler.successfulSwaps(), 2050);
        assertEq(handler.hook().pass(), 3);
        assertEq(handler.rejectedSwaps(), 2);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PixelPoolQuote0SequenceTest is PixelPoolSequenceBase {
    function setUp() public {
        _setup(true);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PixelPoolQuote1SequenceTest is PixelPoolSequenceBase {
    function setUp() public {
        _setup(false);
    }
}
