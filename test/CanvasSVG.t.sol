// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CanvasSVG} from "../src/CanvasSVG.sol";

contract CanvasSVGTest is Test {
    function testFuzz_base64MatchesIndependentEncoder(bytes memory data) public pure {
        assertEq(CanvasSVG.uri(string(data)), string.concat("data:image/svg+xml;base64,", vm.toBase64(data)));
    }

    function test_base64PaddingAndEmptyInput() public pure {
        assertEq(CanvasSVG.uri(""), "data:image/svg+xml;base64,");
        assertEq(CanvasSVG.uri("f"), "data:image/svg+xml;base64,Zg==");
        assertEq(CanvasSVG.uri("fo"), "data:image/svg+xml;base64,Zm8=");
        assertEq(CanvasSVG.uri("foo"), "data:image/svg+xml;base64,Zm9v");
        assertEq(CanvasSVG.uri("foobar"), "data:image/svg+xml;base64,Zm9vYmFy");
    }

    function test_bufferHoldsFullCanvasAndMaximumCounterDigits() public pure {
        bytes memory pixels = new bytes(1024);
        for (uint256 i; i < 1024; ++i) {
            pixels[i] = bytes1(uint8(i % 9));
        }
        string memory svg = CanvasSVG.render(pixels, type(uint256).max, type(uint256).max);
        bytes memory rendered = bytes(svg);
        assertLt(rendered.length, 32_768);
        assertGt(rendered.length, 20_000);
        bytes memory footer = bytes(
            string.concat(
                "PIXEL POOL  pass ",
                vm.toString(type(uint256).max),
                "  swaps ",
                vm.toString(type(uint256).max),
                "</text></svg>"
            )
        );
        uint256 offset = rendered.length - footer.length;
        for (uint256 i; i < footer.length; ++i) {
            assertEq(rendered[offset + i], footer[i]);
        }
    }
}
