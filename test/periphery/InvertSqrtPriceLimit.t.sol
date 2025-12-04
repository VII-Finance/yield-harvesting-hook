// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library InvertSqrtPriceLimit {
    function invertSqrtPriceX96(uint160 x) internal pure returns (uint160 invX) {
        invX = uint160((2 ** 192) / x);
        if (invX <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (invX >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
    }
}

contract InvertSqrtPriceLimitTest is Test {
    using InvertSqrtPriceLimit for uint160;

    function test_invertSqrtPriceX96_Symmetry(uint160 sqrtPriceX96) public pure {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1));

        uint160 inverted = InvertSqrtPriceLimit.invertSqrtPriceX96(sqrtPriceX96);
        uint160 doubleInverted = InvertSqrtPriceLimit.invertSqrtPriceX96(inverted);

        assertApproxEqRel(sqrtPriceX96, doubleInverted, 1e10);
    }

    function test_invertSqrtPriceX96_ValidRange(uint160 sqrtPriceX96) public pure {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1));

        uint160 result = InvertSqrtPriceLimit.invertSqrtPriceX96(sqrtPriceX96);

        // Result should always be within valid range
        assertGe(result, TickMath.MIN_SQRT_PRICE);
        assertLe(result, TickMath.MAX_SQRT_PRICE);
    }

    function test_invertSqrtPriceX96_SpecificTicks(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);

        uint160 inverted = InvertSqrtPriceLimit.invertSqrtPriceX96(sqrtPrice);
        uint160 expected = TickMath.getSqrtPriceAtTick(-tick);

        assertApproxEqRel(inverted, expected, 1e10); //very small difference is ok
    }
}
