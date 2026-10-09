// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @dev Test-only router. Native currency tests fund this helper directly.
contract PoolActions is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return
            abi.decode(
                manager.unlock(abi.encode(msg.sender, key, false, abi.encode(params), bytes(""))), (BalanceDelta)
            );
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData) external returns (BalanceDelta) {
        return
            abi.decode(manager.unlock(abi.encode(msg.sender, key, true, abi.encode(params), hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, bool isSwap, bytes memory params, bytes memory hookData) =
            abi.decode(data, (address, PoolKey, bool, bytes, bytes));
        BalanceDelta delta;
        if (isSwap) delta = manager.swap(key, abi.decode(params, (SwapParams)), hookData);
        else (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), hookData);
        settle(key.currency0, delta.amount0(), payer);
        settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 delta, address payer) private {
        if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
                manager.settle();
            }
        }
    }
}
