// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CanvasSVG} from "./CanvasSVG.sol";

/// @notice One swap, one dot. No fees, funds, administrator or external calls.
contract PixelPoolHook is IHooks {
    using PoolIdLibrary for PoolKey;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    IPoolManager public immutable poolManager;
    PoolId public poolId;
    bool public quoteIsCurrency0;
    bool private poolSet;
    uint256 public strokes;
    uint256[32] private pixels;

    error NotPoolManager();
    error PoolAlreadySet();
    error WrongPool();
    error HookNotEnabled();
    error InvalidPixel();

    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (poolSet) revert PoolAlreadySet();
        poolSet = true;
        poolId = key.toId();
        address currency0 = Currency.unwrap(key.currency0);
        quoteIsCurrency0 = currency0 == IMD || currency0 == address(0);
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!poolSet || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        // Widen before negation so even int128.min has a representable magnitude.
        int256 quote = quoteIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 amount = uint256(quote < 0 ? -quote : quote);
        uint8 shade = amount < 5 ether ? 0 : amount < 50 ether ? 1 : amount < 500 ether ? 2 : 3;
        uint8 color = (params.zeroForOne == quoteIsCurrency0 ? 1 : 5) + shade;
        uint256 stroke = ++strokes;
        uint256 pixel = (stroke - 1) % 1024;
        uint256 shift = (pixel % 32) * 8;
        uint256 slot = pixel / 32;
        pixels[slot] = (pixels[slot] & ~(uint256(255) << shift)) | (uint256(color) << shift);
        // Attribution only: tx.origin grants no authority and need not be the economic trader.
        emit Painted(stroke, pixel, color, tx.origin);
        return (IHooks.afterSwap.selector, 0);
    }

    function pass() public view returns (uint256) {
        return strokes == 0 ? 1 : 1 + (strokes - 1) / 1024;
    }

    function pixelAt(uint256 i) public view returns (uint8) {
        if (i >= 1024) revert InvalidPixel();
        return uint8(pixels[i / 32] >> ((i % 32) * 8));
    }

    function canvas() public view returns (bytes memory data) {
        data = new bytes(1024);
        for (uint256 row; row < 32; ++row) {
            uint256 packed = pixels[row];
            for (uint256 col; col < 32; ++col) {
                data[row * 32 + col] = bytes1(uint8(packed >> (col * 8)));
            }
        }
    }

    function palette(uint256 i) public pure returns (bytes7) {
        return CanvasSVG.palette(i);
    }

    function render() public view returns (string memory) {
        return CanvasSVG.render(canvas(), pass(), strokes);
    }

    function renderURI() external view returns (string memory) {
        return CanvasSVG.uri(render());
    }

    // Disabled callbacks still authenticate the caller, then refuse unexpected manager calls.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotEnabled();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotEnabled();
    }
}
