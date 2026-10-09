// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PixelPoolHook} from "../src/PixelPoolHook.sol";
import {PixelPoolToken} from "../src/PixelPoolToken.sol";

/// @notice Offline CREATE2 planning for the actual launch factory; never broadcasts.
contract PlanDeployment {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG;

    error MissingDeploymentArgument();
    error SaltNotFound();

    function predict(address factory, bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
    }

    function run(address factory, IPoolManager manager)
        external
        pure
        returns (bytes32 tokenSalt, address token, bytes32 hookSalt, address hook)
    {
        if (factory == address(0) || address(manager) == address(0)) revert MissingDeploymentArgument();
        (tokenSalt, token) = mineToken(factory);
        (hookSalt, hook) = mineHook(factory, manager);
    }

    function mineToken(address factory) public pure returns (bytes32 salt, address token) {
        if (factory == address(0)) revert MissingDeploymentArgument();
        bytes32 codeHash = keccak256(type(PixelPoolToken).creationCode);
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            token = predict(factory, salt, codeHash);
            if (uint160(token) > uint160(IMD)) return (salt, token);
        }
        revert SaltNotFound();
    }

    function mineHook(address factory, IPoolManager manager) public pure returns (bytes32 salt, address hook) {
        if (factory == address(0) || address(manager) == address(0)) revert MissingDeploymentArgument();
        bytes32 codeHash = keccak256(abi.encodePacked(type(PixelPoolHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            hook = predict(factory, salt, codeHash);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == FLAGS) return (salt, hook);
        }
        revert SaltNotFound();
    }
}
