// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IVaultWrapper {
    function harvest(address poolManager) external returns (uint256 harvestedAssets, uint256 fees);
    function pendingYield() external view returns (uint256, uint256);
    function totalPendingYield() external view returns (uint256);
    function feeDivisor() external view returns (uint256);
    function feeReceiver() external view returns (address);
}
