// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelPoolToken} from "../src/PixelPoolToken.sol";

contract PixelPoolTokenTest is Test {
    PixelPoolToken token;
    address recipient;
    address spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new PixelPoolToken();
        recipient = makeAddr("recipient");
        spender = makeAddr("spender");
    }

    function test_metadataAndWholeSupplyBelongToDeployer() public view {
        assertEq(token.name(), "Pixel Pool");
        assertEq(token.symbol(), "PIXEL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferConservesFixedSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), recipient, amount);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_approvalAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 20 ether);
        assertTrue(token.approve(spender, 20 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 7 ether));
        assertEq(token.allowance(address(this), spender), 13 ether);
        assertEq(token.balanceOf(recipient), 7 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - 7 ether);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(PixelPoolToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), recipient, 1);
    }

    function test_infiniteApprovalDoesNotDecrease() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 7 ether);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
    }

    function test_selfTransferAndZeroTransfer() public {
        token.transfer(address(this), 7 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        token.transfer(recipient, 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_zeroAddressesRefused() public {
        vm.expectRevert(PixelPoolToken.InvalidAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(PixelPoolToken.InvalidAddress.selector);
        token.approve(address(0), 1);
        vm.expectRevert(PixelPoolToken.InvalidAddress.selector);
        token.transferFrom(address(0), recipient, 0);
    }

    function test_insufficientBalanceAndAllowanceRevertWithoutChangingState() public {
        uint256 excess = token.totalSupply() + 1;
        vm.expectRevert(PixelPoolToken.InsufficientBalance.selector);
        token.transfer(recipient, excess);
        vm.prank(spender);
        vm.expectRevert(PixelPoolToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), recipient, 1);
        vm.prank(recipient);
        token.approve(spender, 5 ether);
        vm.prank(spender);
        vm.expectRevert(PixelPoolToken.InsufficientBalance.selector);
        token.transferFrom(recipient, address(this), 5 ether);
        assertEq(token.allowance(recipient, spender), 5 ether, "reverted transfer restores allowance");
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_noMintAdministrationOrUpgradeFromDeployerOrStranger() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory callData = abi.encodeWithSignature(signatures[i], recipient, 1 ether);
            (bool success,) = address(token).call(callData);
            assertFalse(success);
            vm.prank(spender);
            (success,) = address(token).call(callData);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_runtimeHasNoMutableImplementationOrSelfDestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
