// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract YieldHarvestingHookTest is Test {
    PoolManager public poolManager;
    address public poolManagerOwner = makeAddr("poolManagerOwner");

    function setUp() public {
        poolManager = new PoolManager(poolManagerOwner);
    }
}
