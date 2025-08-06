// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {AaveWrapper} from "src/VaultWrappers/AaveWrapper.sol";

contract MockAaveWrapper is AaveWrapper {
    function _maxAssetsSuppliableToAave() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    function _maxAssetsWithdrawableFromAave() internal pure override returns (uint256) {
        return type(uint256).max;
    }
}
