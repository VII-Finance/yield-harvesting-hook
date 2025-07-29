// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IVaultWrapper {
    function yieldHarvestingHook() external view returns (address);
    function harvest(address poolManager) external returns (uint256 harvestedAssets);

    function pendingYield() external view returns (uint256);
}
