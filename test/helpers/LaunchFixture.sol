// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PixelPoolToken} from "../../src/PixelPoolToken.sol";
import {PixelPoolHook} from "../../src/PixelPoolHook.sol";

/// @dev Test-only factory reproducing atomic deployment and initialization, using raw CREATE2 salts.
contract LaunchFixture {
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function launch(IPoolManager manager, bytes32 tokenSalt, bytes32 hookSalt, uint160 price)
        external
        returns (PixelPoolToken token, PixelPoolHook hook, PoolKey memory key)
    {
        token = new PixelPoolToken{salt: tokenSalt}();
        hook = new PixelPoolHook{salt: hookSalt}(manager);
        require(address(token) > IMD, "PIXEL must sort after IMD");
        key = PoolKey(Currency.wrap(IMD), Currency.wrap(address(token)), 12500, 60, hook);
        manager.initialize(key, price);
        require(token.transfer(msg.sender, token.totalSupply()));
    }

    function deployHook(IPoolManager manager, bytes32 salt) external returns (PixelPoolHook) {
        return new PixelPoolHook{salt: salt}(manager);
    }

    function deployToken(bytes32 salt) external returns (PixelPoolToken token) {
        token = new PixelPoolToken{salt: salt}();
        require(token.transfer(msg.sender, token.totalSupply()));
    }
}
