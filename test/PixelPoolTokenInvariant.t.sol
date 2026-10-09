// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelPoolToken} from "src/PixelPoolToken.sol";

/// @dev Closed actor set: no deal/mint cheats or untracked recipients after deployment.
contract PixelTokenHandler is Test {
    PixelPoolToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public transfers;
    uint256 public approvals;
    uint256 public refusals;

    constructor() {
        token = new PixelPoolToken();
        actors = [address(this), makeAddr("pixel alice"), makeAddr("pixel bob"), makeAddr("pixel carol")];
        expectedBalance[address(this)] = 1_000_000_000 ether;
        // Start every actor with real tokens; the remaining supply stays with the deployer.
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], 100_000_000 ether);
            _move(address(this), actors[i], 100_000_000 ether);
        }
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = spenderSeed % 5 == 4 ? address(0) : actors[spenderSeed % 4];
        vm.prank(owner);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.approve, (spender, amount)));
        if (spender == address(0)) {
            _refused(ok, result, PixelPoolToken.InvalidAddress.selector);
        } else {
            assertTrue(ok, "valid approval failed");
            assertTrue(abi.decode(result, (bool)));
            expectedAllowance[owner][spender] = amount;
            ++approvals;
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 seed, uint8 mode) external {
        address from = actors[fromSeed % 4];
        address to = toSeed % 5 == 4 ? address(0) : actors[toSeed % 4];
        uint256 amount = _amount(seed, expectedBalance[from], mode);
        vm.prank(from);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        if (to == address(0)) {
            _refused(ok, result, PixelPoolToken.InvalidAddress.selector);
        } else if (amount > expectedBalance[from]) {
            _refused(ok, result, PixelPoolToken.InsufficientBalance.selector);
        } else {
            assertTrue(ok, "funded transfer failed");
            assertTrue(abi.decode(result, (bool)));
            _move(from, to, amount);
        }
    }

    function transferFrom(uint8 fromSeed, uint8 toSeed, uint8 spenderSeed, uint256 seed, uint8 mode) external {
        address from = fromSeed % 5 == 4 ? address(0) : actors[fromSeed % 4];
        address to = toSeed % 5 == 4 ? address(0) : actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = _amount(seed, expectedBalance[from], mode);
        uint256 allowed = expectedAllowance[from][spender];
        vm.prank(spender);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        if (allowed < amount) {
            _refused(ok, result, PixelPoolToken.InsufficientAllowance.selector);
        } else if (from == address(0) || to == address(0)) {
            _refused(ok, result, PixelPoolToken.InvalidAddress.selector);
        } else if (amount > expectedBalance[from]) {
            _refused(ok, result, PixelPoolToken.InsufficientBalance.selector);
        } else {
            assertTrue(ok, "authorized funded transferFrom failed");
            assertTrue(abi.decode(result, (bool)));
            if (allowed != type(uint256).max) expectedAllowance[from][spender] -= amount;
            _move(from, to, amount);
        }
    }

    /// @dev Ensure the random campaign exercises successful delegated spending, including max approval.
    function approveAndSpend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 seed, bool unlimited) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(seed, 0, expectedBalance[owner]);
        uint256 approval = unlimited ? type(uint256).max : amount;
        vm.prank(owner);
        assertTrue(token.approve(spender, approval));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedAllowance[owner][spender] = unlimited ? type(uint256).max : 0;
        ++approvals;
        _move(owner, to, amount);
    }

    function _amount(uint256 seed, uint256 balance, uint8 mode) private pure returns (uint256) {
        if (mode % 6 == 0) return 0;
        if (mode % 6 == 1) return balance;
        if (mode % 6 == 2) return balance + 1;
        if (mode % 6 == 3) return type(uint256).max;
        return bound(seed, 0, balance);
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ++transfers;
    }

    function _refused(bool ok, bytes memory reason, bytes4 selector) private {
        assertFalse(ok, "invalid operation succeeded");
        assertEq(reason, abi.encodeWithSelector(selector), "unexpected failure");
        ++refusals;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PixelPoolTokenInvariantTest is Test {
    PixelTokenHandler handler;
    PixelPoolToken token;

    function setUp() public {
        handler = new PixelTokenHandler();
        token = handler.token();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.approveAndSpend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyBalancesAndAllowancesMatchModel() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            uint256 balance = token.balanceOf(owner);
            assertEq(balance, handler.expectedBalance(owner), "balance differs from successful transfers");
            sum += balance;
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
        assertEq(sum, 1_000_000_000 ether, "tokens created, destroyed or leaked");
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_handlerExercisesAllowanceRollbackSelfTransfersAndRevocation() public {
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(0, 0, 1, 0, 1); // Self transfer of the entire supply held by actor 0.
        handler.transferFrom(0, 2, 1, 0, 2); // Sufficient allowance, insufficient balance.
        handler.approveAndSpend(1, 2, 3, 7 ether, false);
        handler.approve(0, 1, 0);
        handler.transferFrom(0, 2, 1, 1, 4); // Revoked approval must stay revoked.
        handler.transfer(0, 4, 0, 0); // Zero transfer still refuses the zero address.
        invariant_fixedSupplyBalancesAndAllowancesMatchModel();
        assertGt(handler.transfers(), 3);
        assertEq(handler.refusals(), 3);
    }
}
