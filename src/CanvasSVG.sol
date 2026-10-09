// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Bounded SVG writer. Each append copies into one preallocated output buffer.
library CanvasSVG {
    error InvalidColor();

    function palette(uint256 i) internal pure returns (bytes7) {
        if (i > 8) revert InvalidColor();
        bytes memory colors = "#0b0b12#1f7a3d#22b455#2ee66b#8dffad#7a1f1f#c42b2b#ff3b3b#ff9a9a";
        bytes7 color;
        assembly ("memory-safe") {
            color := mload(add(add(colors, 32), mul(i, 7)))
        }
        return color;
    }

    function render(bytes memory pixels, uint256 currentPass, uint256 strokes) internal pure returns (string memory) {
        // At most 24 bytes per dot, nine path headers, fixed markup and two uint256s.
        bytes memory out = new bytes(32_768);
        uint256 p = append(
            out,
            0,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 36"><rect width="32" height="36" fill="#0b0b12"/>'
        );
        for (uint8 color; color < 9; ++color) {
            p = append(out, p, '<path fill="');
            bytes7 hexColor = palette(color);
            for (uint256 j; j < 7; ++j) {
                out[p++] = hexColor[j];
            }
            p = append(out, p, '" d="');
            for (uint256 i; i < 1024; ++i) {
                if (uint8(pixels[i]) != color) continue;
                out[p++] = "M";
                p = number(out, p, i % 32);
                p = append(out, p, ".1 ");
                p = number(out, p, i / 32);
                p = append(out, p, ".1h.8v.8h-.8z");
            }
            p = append(out, p, '"/>');
        }
        p = append(
            out,
            p,
            '<text x="1" y="34.5" fill="#ffffff" font-family="monospace" font-size="1" xml:space="preserve">PIXEL POOL  pass '
        );
        p = number(out, p, currentPass);
        p = append(out, p, "  swaps ");
        p = number(out, p, strokes);
        p = append(out, p, "</text></svg>");
        assembly ("memory-safe") {
            mstore(out, p)
        }
        return string(out);
    }

    function uri(string memory svg) internal pure returns (string memory) {
        bytes memory data = bytes(svg);
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLength = 4 * ((data.length + 2) / 3);
        bytes memory out = new bytes(26 + encodedLength);
        uint256 p = append(out, 0, "data:image/svg+xml;base64,");
        // The prefix is 26 bytes. Padding is written explicitly for both partial groups.
        for (uint256 i; i < data.length; i += 3) {
            uint256 n = uint256(uint8(data[i])) << 16;
            if (i + 1 < data.length) n |= uint256(uint8(data[i + 1])) << 8;
            if (i + 2 < data.length) n |= uint256(uint8(data[i + 2]));
            out[p++] = alphabet[(n >> 18) & 63];
            out[p++] = alphabet[(n >> 12) & 63];
            out[p++] = i + 1 < data.length ? alphabet[(n >> 6) & 63] : bytes1("=");
            out[p++] = i + 2 < data.length ? alphabet[n & 63] : bytes1("=");
        }
        return string(out);
    }

    function append(bytes memory out, uint256 p, bytes memory value) private pure returns (uint256 end) {
        end = p + value.length;
        assert(end <= out.length);
        assembly ("memory-safe") {
            mcopy(add(add(out, 32), p), add(value, 32), mload(value))
        }
    }

    function number(bytes memory out, uint256 p, uint256 value) private pure returns (uint256 end) {
        uint256 digits = 1;
        for (uint256 n = value; n >= 10; n /= 10) {
            ++digits;
        }
        end = p + digits;
        assert(end <= out.length);
        uint256 cursor = end;
        do {
            out[--cursor] = bytes1(uint8(48 + value % 10));
            value /= 10;
        } while (cursor > p);
    }
}
