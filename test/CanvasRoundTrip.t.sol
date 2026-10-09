// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CanvasSVG} from "src/CanvasSVG.sol";

/// @dev Decodes the SVG geometry back into an image. Merely counting paths cannot catch a
/// transposed canvas, a missing dot replaced by a duplicate, or the right shape in the wrong color.
contract CanvasRoundTripTest is Test {
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_allCoordinatesAndColorsSurviveRendering(bytes32 seed, uint256 pass, uint256 strokes) public pure {
        bytes memory pixels = new bytes(1024);
        for (uint256 row; row < 32; ++row) {
            bytes32 random = keccak256(abi.encode(seed, row));
            for (uint256 col; col < 32; ++col) {
                pixels[row * 32 + col] = bytes1(uint8(random[col]) % 9);
            }
        }
        _roundTrip(pixels, pass, strokes);
    }

    function test_allEmptyAndAllUniformColorsRoundTrip() public pure {
        for (uint8 color; color < 9; ++color) {
            bytes memory pixels = new bytes(1024);
            for (uint256 i; i < 1024; ++i) {
                pixels[i] = bytes1(color);
            }
            _roundTrip(pixels, 1, color == 0 ? 0 : 1024);
        }
    }

    function test_footerDigitTransitionsAndBase64HaveNoTrailingBytes() public pure {
        uint256[7] memory counts = [uint256(0), 1, 9, 10, 1024, 1025, type(uint256).max];
        bytes memory pixels = new bytes(1024);
        for (uint256 i; i < counts.length; ++i) {
            uint256 strokes = counts[i];
            uint256 pass = strokes == 0 ? 1 : (strokes - 1) / 1024 + 1;
            bytes memory svg = bytes(CanvasSVG.render(pixels, pass, strokes));
            _footer(svg, pass, strokes);
            assertEq(CanvasSVG.uri(string(svg)), string.concat("data:image/svg+xml;base64,", vm.toBase64(svg)));
        }
    }

    function _roundTrip(bytes memory pixels, uint256 pass, uint256 strokes) private pure {
        bytes memory svg = bytes(CanvasSVG.render(pixels, pass, strokes));
        _find(svg, bytes('viewBox="0 0 32 36"'), 0);
        _find(svg, bytes('<rect width="32" height="36" fill="#0b0b12"/>'), 0);
        bytes memory decoded = new bytes(1024);
        bool[1024] memory seen;
        bool[9] memory usedColor;
        uint256 cursor;
        uint256 dotCount;
        for (uint256 path; path < 9; ++path) {
            cursor = _find(svg, bytes('<path fill="'), cursor);
            uint8 color = _color(svg, cursor);
            assertFalse(usedColor[color], "more than one path for a color");
            usedColor[color] = true;
            cursor = _consume(svg, cursor + 7, bytes('" d="'));
            while (svg[cursor] != '"') {
                uint256 x;
                uint256 y;
                cursor = _consume(svg, cursor, bytes("M"));
                (x, cursor) = _coordinate(svg, cursor);
                cursor = _consume(svg, cursor, bytes(" "));
                (y, cursor) = _coordinate(svg, cursor);
                cursor = _consume(svg, cursor, bytes("h.8v.8h-.8z"));
                uint256 pixel = y * 32 + x;
                assertFalse(seen[pixel], "duplicate dot coordinates");
                seen[pixel] = true;
                decoded[pixel] = bytes1(color);
                ++dotCount;
            }
            cursor = _consume(svg, cursor, bytes('"/>'));
        }
        assertEq(dotCount, 1024, "canvas has gaps");
        assertEq(decoded, pixels, "rendered location or palette does not match the canvas");
        // Nothing may be silently appended to the geometry after the nine decoded paths.
        _consume(svg, cursor, bytes('<text x="1" y="34.5"'));
        _footer(svg, pass, strokes);
    }

    function _color(bytes memory svg, uint256 cursor) private pure returns (uint8) {
        bytes7[9] memory palette =
            [bytes7("#0b0b12"), "#1f7a3d", "#22b455", "#2ee66b", "#8dffad", "#7a1f1f", "#c42b2b", "#ff3b3b", "#ff9a9a"];
        for (uint8 color; color < 9; ++color) {
            bool matches = true;
            for (uint256 i; i < 7; ++i) {
                if (svg[cursor + i] != palette[color][i]) matches = false;
            }
            if (matches) return color;
        }
        revert("unknown SVG palette color");
    }

    function _coordinate(bytes memory svg, uint256 cursor) private pure returns (uint256 value, uint256 end) {
        uint256 start = cursor;
        while (svg[cursor] >= "0" && svg[cursor] <= "9") {
            value = 10 * value + uint8(svg[cursor]) - 48;
            ++cursor;
        }
        assertGt(cursor, start, "missing coordinate");
        assertLt(value, 32, "dot outside canvas");
        end = _consume(svg, cursor, bytes(".1"));
    }

    function _footer(bytes memory svg, uint256 pass, uint256 strokes) private pure {
        bytes memory expected = bytes(
            string.concat("PIXEL POOL  pass ", vm.toString(pass), "  swaps ", vm.toString(strokes), "</text></svg>")
        );
        uint256 end = _consume(svg, svg.length - expected.length, expected);
        assertEq(end, svg.length);
    }

    function _consume(bytes memory data, uint256 cursor, bytes memory literal) private pure returns (uint256) {
        for (uint256 i; i < literal.length; ++i) {
            assertEq(data[cursor + i], literal[i], "invalid SVG geometry");
        }
        return cursor + literal.length;
    }

    /// @return The offset immediately after the first matching literal.
    function _find(bytes memory data, bytes memory literal, uint256 start) private pure returns (uint256) {
        for (uint256 i = start; i + literal.length <= data.length; ++i) {
            if (data[i] != literal[0]) continue;
            uint256 j = 1;
            while (j < literal.length && data[i + j] == literal[j]) ++j;
            if (j == literal.length) return i + literal.length;
        }
        revert("missing SVG element");
    }
}
