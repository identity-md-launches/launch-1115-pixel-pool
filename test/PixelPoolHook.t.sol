// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PixelPoolHook} from "../src/PixelPoolHook.sol";
import {PixelPoolToken} from "../src/PixelPoolToken.sol";
import {CanvasSVG} from "../src/CanvasSVG.sol";
import {PlanDeployment} from "../script/PlanDeployment.s.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolActions} from "./helpers/PoolActions.sol";

contract PixelPoolHookTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 constant ONE = 79228162514264337593543950336;
    uint160 constant OPENING_PRICE = 50108289675009586237282760313921;
    int256 constant LIQUIDITY = 1_000_000 ether;

    IPoolManager manager;
    PixelPoolToken token;
    PixelPoolToken quote;
    PixelPoolHook hook;
    PoolActions router;
    PlanDeployment planner;
    PoolKey key;

    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolActions(manager);
        planner = new PlanDeployment();
        // Local IMD model with 18 decimals; no production chain or RPC needed.
        vm.etch(IMD, address(new PixelPoolToken()).code);
        quote = PixelPoolToken(IMD);
        deal(IMD, address(this), 1_000_000_000 ether);
        LaunchFixture factory = new LaunchFixture();
        (bytes32 tokenSalt,, bytes32 hookSalt,) = planner.run(address(factory), manager);
        (token, hook, key) = factory.launch(manager, tokenSalt, hookSalt, ONE);
        _seed(token, key, LIQUIDITY);
    }

    function _seed(PixelPoolToken launchToken, PoolKey memory poolKey, int256 liquidity) internal {
        launchToken.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        router.liquidity(poolKey, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0)));
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 specified) internal returns (BalanceDelta) {
        return router.swap(poolKey, _params(zeroForOne, specified), "");
    }

    function _params(bool zeroForOne, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _freshHook() internal returns (PixelPoolHook fresh) {
        LaunchFixture factory = new LaunchFixture();
        (bytes32 salt,) = planner.mineHook(address(factory), manager);
        fresh = factory.deployHook(manager, salt);
    }

    function _quoteAsCurrency1() internal returns (PixelPoolHook other, PoolKey memory otherKey) {
        LaunchFixture factory = new LaunchFixture();
        bytes32 codeHash = keccak256(type(PixelPoolToken).creationCode);
        uint256 salt;
        while (planner.predict(address(factory), bytes32(salt), codeHash) >= IMD) ++salt;
        PixelPoolToken lowToken = factory.deployToken(bytes32(salt));
        assertLt(uint160(address(lowToken)), uint160(IMD));
        (bytes32 hookSalt,) = planner.mineHook(address(factory), manager);
        other = factory.deployHook(manager, hookSalt);
        otherKey = PoolKey(Currency.wrap(address(lowToken)), Currency.wrap(IMD), 12500, 60, other);
        manager.initialize(otherKey, ONE);
        _seed(lowToken, otherKey, LIQUIDITY);
    }

    function test_plannedDeploymentCreatesPixelAboveImdAtOpeningPrice() public {
        LaunchFixture factory = new LaunchFixture();
        (bytes32 tokenSalt, address plannedToken, bytes32 hookSalt, address plannedHook) =
            planner.run(address(factory), manager);
        assertGt(uint160(plannedToken), uint160(IMD));
        assertEq(uint160(plannedHook) & Hooks.ALL_HOOK_MASK, 0x2040);
        (PixelPoolToken launchedToken, PixelPoolHook launchedHook, PoolKey memory launchKey) =
            factory.launch(manager, tokenSalt, hookSalt, OPENING_PRICE);
        assertEq(address(launchedToken), plannedToken);
        assertEq(address(launchedHook), plannedHook);
        assertTrue(launchedHook.quoteIsCurrency0());
        assertEq(Currency.unwrap(launchKey.currency0), IMD);
        assertEq(Currency.unwrap(launchKey.currency1), plannedToken);
        (uint160 price,,, uint24 fee) = manager.getSlot0(launchKey.toId());
        assertEq(price, OPENING_PRICE);
        assertEq(fee, 12500);
        assertEq(launchedToken.balanceOf(address(this)), 1_000_000_000 ether);
        _seed(launchedToken, launchKey, LIQUIDITY);
        BalanceDelta delta = _swap(launchKey, true, -10 ether);
        assertEq(delta.amount0(), -10 ether);
        assertGt(delta.amount1(), 500 ether);
        assertEq(launchedHook.pixelAt(0), 2, "shade must use IMD, not PIXEL");
        delta = _swap(launchKey, false, 1 ether);
        assertEq(delta.amount0(), 1 ether);
        assertLt(delta.amount1(), -500 ether);
        assertEq(launchedHook.pixelAt(1), 5);
    }

    function test_permissionsAndInitialState() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x2040);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertTrue(hook.quoteIsCurrency0());
        assertEq(hook.strokes(), 0);
        assertEq(hook.pass(), 1);
        assertEq(hook.canvas(), new bytes(1024));
    }

    function test_wrongPermissionAddressRefusesDeployment() public {
        bytes32 salt = keccak256("invalid permission test");
        bytes32 codeHash = keccak256(abi.encodePacked(type(PixelPoolHook).creationCode, abi.encode(manager)));
        address predicted = planner.predict(address(this), salt, codeHash);
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x2040);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new PixelPoolHook{salt: salt}(manager);
    }

    function test_buysAndSellsExactInputAndOutputQuote0() public {
        _swap(key, true, -1 ether);
        _swap(key, false, -1 ether);
        _swap(key, true, 1 ether);
        _swap(key, false, 1 ether);
        assertEq(hook.pixelAt(0), 1);
        assertEq(hook.pixelAt(1), 5);
        assertEq(hook.pixelAt(2), 1);
        assertEq(hook.pixelAt(3), 5);
        assertEq(hook.pixelAt(4), 0);
    }

    function test_buysAndSellsExactInputAndOutputQuote1() public {
        (PixelPoolHook other, PoolKey memory otherKey) = _quoteAsCurrency1();
        assertFalse(other.quoteIsCurrency0());
        _swap(otherKey, false, -1 ether);
        _swap(otherKey, true, -1 ether);
        _swap(otherKey, false, 1 ether);
        _swap(otherKey, true, 1 ether);
        assertEq(other.pixelAt(0), 1);
        assertEq(other.pixelAt(1), 5);
        assertEq(other.pixelAt(2), 1);
        assertEq(other.pixelAt(3), 5);
        assertEq(hook.strokes(), 0, "canvases are independent");
    }

    function _brightness(PixelPoolHook target, PoolKey memory poolKey, bool quote0) internal {
        int256[8] memory sizes =
            [int256(1), 5 ether - 1, 5 ether, 50 ether - 1, 50 ether, 500 ether - 1, 500 ether, 1000 ether];
        uint8[8] memory shades = [0, 0, 1, 1, 2, 2, 3, 3];
        for (uint256 i; i < sizes.length; ++i) {
            _swap(poolKey, quote0, -sizes[i]); // Buy with exact quote input.
            _swap(poolKey, !quote0, sizes[i]); // Sell for exact quote output.
            assertEq(target.pixelAt(2 * i), 1 + shades[i]);
            assertEq(target.pixelAt(2 * i + 1), 5 + shades[i]);
        }
    }

    function test_shadeThresholdsQuote0() public {
        _brightness(hook, key, true);
    }

    function test_shadeThresholdsQuote1() public {
        (PixelPoolHook other, PoolKey memory otherKey) = _quoteAsCurrency1();
        _brightness(other, otherKey, false);
    }

    function test_sequentialDotsAndSecondPassRepaintOnlyDotsZeroAndOne() public {
        for (uint256 i; i < 1024; ++i) {
            _swap(key, i % 2 == 0, -1 ether);
            assertEq(hook.strokes(), i + 1);
            assertEq(hook.pixelAt(i), i % 2 == 0 ? 1 : 5);
            if (i < 1023) assertEq(hook.pixelAt(i + 1), 0);
        }
        assertEq(hook.pass(), 1);
        bytes memory beforeCanvas = hook.canvas();
        _swap(key, false, 500 ether);
        assertEq(hook.pass(), 2);
        _swap(key, true, -500 ether);
        assertEq(hook.strokes(), 1026);
        assertEq(hook.pixelAt(0), 8);
        assertEq(hook.pixelAt(1), 4);
        bytes memory afterCanvas = hook.canvas();
        for (uint256 i = 2; i < 1024; ++i) {
            assertEq(afterCanvas[i], beforeCanvas[i]);
        }
    }

    function test_eventUsesOriginNotRouterOrHookData() public {
        address painter = makeAddr("transaction origin");
        vm.expectEmit(true, true, true, true, address(hook));
        emit Painted(1, 0, 1, painter);
        vm.prank(address(this), painter);
        router.swap(key, _params(true, -1 ether), abi.encode(makeAddr("fake painter")));
    }

    function test_secondPoolInitializationRevertsAndFirstPoolStillWorks() public {
        PoolKey memory second = key;
        second.fee = 3000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PixelPoolHook.PoolAlreadySet.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(second, ONE);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        _swap(key, true, -1 ether);
        assertEq(hook.strokes(), 1);
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.PoolAlreadySet.selector);
        hook.beforeInitialize(address(this), key, ONE);
    }

    function test_failedInitializeRollsBackPoolLock() public {
        PixelPoolHook fresh = _freshHook();
        PoolKey memory freshKey = key;
        freshKey.hooks = fresh;
        vm.expectRevert();
        manager.initialize(freshKey, TickMath.MIN_SQRT_PRICE - 1);
        manager.initialize(freshKey, ONE);
        assertEq(PoolId.unwrap(fresh.poolId()), PoolId.unwrap(freshKey.toId()));
    }

    function test_wrongPoolAndUninitializedSwapsRefused() public {
        for (uint256 field; field < 5; ++field) {
            PoolKey memory wrong = key;
            if (field == 0) wrong.fee = 3000;
            if (field == 1) wrong.tickSpacing = 10;
            if (field == 2) wrong.currency0 = key.currency1;
            if (field == 3) wrong.currency1 = key.currency0;
            if (field == 4) wrong.hooks = IHooks(address(manager));
            vm.prank(address(manager));
            vm.expectRevert(PixelPoolHook.WrongPool.selector);
            hook.afterSwap(address(router), wrong, _params(true, -1), toBalanceDelta(-1, 1), "");
        }
        PixelPoolHook fresh = _freshHook();
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.WrongPool.selector);
        fresh.afterSwap(address(router), key, _params(true, -1), toBalanceDelta(-1, 1), "");
        assertEq(hook.strokes(), 0);
    }

    function test_allTenCallbacksRequirePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[10] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, ONE)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, ONE, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, _params(true, -1), "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, _params(true, -1), zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(PixelPoolHook.NotPoolManager.selector));
            if (i != 0 && i != 7) {
                vm.prank(address(manager));
                (ok, reason) = address(hook).call(calls[i]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(PixelPoolHook.HookNotEnabled.selector));
            }
        }
    }

    function test_nativeQuoteUsesCurrency0() public {
        PixelPoolHook nativeHook = _freshHook();
        PoolKey memory nativeKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, nativeHook);
        manager.initialize(nativeKey, ONE);
        assertTrue(nativeHook.quoteIsCurrency0());
        vm.deal(address(router), 2_000_000 ether);
        _seed(token, nativeKey, LIQUIDITY);
        _swap(nativeKey, true, -5 ether);
        _swap(nativeKey, false, 5 ether);
        assertEq(nativeHook.pixelAt(0), 2);
        assertEq(nativeHook.pixelAt(1), 6);
        assertEq(address(nativeHook).balance, 0);
    }

    function test_hookHoldsNoFundsOrClaimsAndPoolCanUnwind() public {
        uint256 imdBefore = quote.balanceOf(address(this));
        uint256 pixelBefore = token.balanceOf(address(this));
        BalanceDelta delta = _swap(key, true, -10 ether);
        assertEq(quote.balanceOf(address(this)), imdBefore - uint256(-int256(delta.amount0())));
        assertEq(token.balanceOf(address(this)), pixelBefore + uint128(delta.amount1()));
        _swap(key, false, -10 ether);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, -LIQUIDITY, bytes32(0)));
        assertEq(hook.strokes(), 2, "liquidity changes must not paint");
    }

    function test_failedSettlementRollsBackCanvasAndEvent() public {
        quote.approve(address(router), 0);
        vm.expectRevert(PixelPoolToken.InsufficientAllowance.selector);
        _swap(key, true, -1 ether);
        assertEq(hook.strokes(), 0);
        assertEq(hook.pixelAt(0), 0);
    }

    function test_partialFillShadesByExecutedQuote() public {
        BalanceDelta delta = router.swap(key, SwapParams(true, -1000 ether, ONE - ONE / 1_000_000), "");
        assertLt(uint256(-int256(delta.amount0())), 5 ether);
        assertEq(hook.pixelAt(0), 1, "requested 1000 but executed less than 5 IMD");
    }

    function testFuzz_quoteMagnitudeNotOtherCurrencyOrSpecifiedAmount(int128 amount, int128 other, bool buy) public {
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) =
            hook.afterSwap(address(router), key, _params(buy, -1000 ether), toBalanceDelta(amount, other), "ignored");
        uint256 absolute = uint256(amount < 0 ? -int256(amount) : int256(amount));
        uint256 shade = absolute < 5 ether ? 0 : absolute < 50 ether ? 1 : absolute < 500 ether ? 2 : 3;
        assertEq(hook.pixelAt(0), (buy ? 1 : 5) + shade);
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
    }

    function test_int128MinimumAndZeroAreHandled() public {
        vm.startPrank(address(manager));
        hook.afterSwap(address(router), key, _params(true, -1), toBalanceDelta(type(int128).min, 0), "");
        hook.afterSwap(address(router), key, _params(false, 1), toBalanceDelta(0, type(int128).min), "");
        vm.stopPrank();
        assertEq(hook.pixelAt(0), 4);
        assertEq(hook.pixelAt(1), 5);
    }

    function test_pixelAndPaletteBounds() public {
        vm.expectRevert(PixelPoolHook.InvalidPixel.selector);
        hook.pixelAt(1024);
        vm.expectRevert(PixelPoolHook.InvalidPixel.selector);
        hook.pixelAt(type(uint256).max);
        vm.expectRevert(CanvasSVG.InvalidColor.selector);
        hook.palette(9);
        bytes7[9] memory expected =
            [bytes7("#0b0b12"), "#1f7a3d", "#22b455", "#2ee66b", "#8dffad", "#7a1f1f", "#c42b2b", "#ff3b3b", "#ff9a9a"];
        for (uint256 i; i < 9; ++i) {
            assertEq(hook.palette(i), expected[i]);
        }
    }

    function test_runtimeHasNoExternalCallsOrMutableImplementation() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf1 && op != 0xfa && op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function test_noAdministrationOrRescueSelectors() public {
        string[6] memory signatures = [
            "transferOwnership(address)",
            "upgradeTo(address)",
            "setPool(bytes32)",
            "setFee(uint256)",
            "pause()",
            "withdraw(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool success,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), 1 ether));
            assertFalse(success);
        }
    }

    function testFuzz_plannerRequiresRealArgumentsAndMinesForEachFactory(address first, address second) public {
        vm.assume(first != address(0) && second != address(0));
        (bytes32 firstSalt, address firstToken) = planner.mineToken(first);
        (bytes32 secondSalt, address secondToken) = planner.mineToken(second);
        bytes32 hash = keccak256(type(PixelPoolToken).creationCode);
        assertEq(firstToken, planner.predict(first, firstSalt, hash));
        assertEq(secondToken, planner.predict(second, secondSalt, hash));
        assertGt(uint160(firstToken), uint160(IMD));
        assertGt(uint160(secondToken), uint160(IMD));
        vm.expectRevert(PlanDeployment.MissingDeploymentArgument.selector);
        planner.run(address(0), manager);
        vm.expectRevert(PlanDeployment.MissingDeploymentArgument.selector);
        planner.run(first, IPoolManager(address(0)));
    }

    function test_fullCanvasRenderUnder15MillionGas() public {
        int256[4] memory amounts = [int256(1 ether), 10 ether, 100 ether, 500 ether];
        for (uint256 i; i < 1024; ++i) {
            uint256 shade = (i / 2) % 4;
            _swap(key, i % 2 == 0, i % 2 == 0 ? -amounts[shade] : amounts[shade]);
        }
        // Include cold canvas reads even though the painting happened in this test transaction.
        vm.cool(address(hook));
        uint256 gasBefore = gasleft();
        string memory svg = hook.render();
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("full canvas render gas", used);
        assertLt(used, 15_000_000);
        assertEq(_count(bytes(svg), bytes('<path fill="')), 9);
        assertEq(_count(bytes(svg), bytes("h.8v.8h-.8z")), 1024);
        assertEq(_count(bytes(svg), bytes('viewBox="0 0 32 36"')), 1);
        assertEq(_count(bytes(svg), bytes("M0.1 0.1h.8v.8h-.8z")), 1);
        assertEq(_count(bytes(svg), bytes("M31.1 31.1h.8v.8h-.8z")), 1);
        assertEq(_count(bytes(svg), bytes("PIXEL POOL  pass 1  swaps 1024")), 1);
        assertEq(hook.renderURI(), string.concat("data:image/svg+xml;base64,", vm.toBase64(bytes(svg))));
    }

    function test_emptyRenderAndURI() public view {
        string memory svg = hook.render();
        assertEq(_count(bytes(svg), bytes("PIXEL POOL  pass 1  swaps 0")), 1);
        assertEq(_count(bytes(svg), bytes("h.8v.8h-.8z")), 1024);
        assertEq(hook.renderURI(), string.concat("data:image/svg+xml;base64,", vm.toBase64(bytes(svg))));
    }

    function _count(bytes memory haystack, bytes memory needle) internal pure returns (uint256 found) {
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            if (haystack[i] != needle[0]) continue;
            uint256 j = 1;
            while (j < needle.length && haystack[i + j] == needle[j]) ++j;
            if (j == needle.length) ++found;
        }
    }

    receive() external payable {}
}
