// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BaseVaultWrapper} from "src/vaultWrappers/base/BaseVaultWrapper.sol";

/**
 * @notice This wrapper is intended for use with Aave's monotonically increasing aTokens.
 * @dev Aave does not have bad debt socialization, so this wrapper will always remain solvent.
 */
contract AaveWrapper is BaseVaultWrapper {
    constructor() BaseVaultWrapper() {}

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    ///@dev for Aave's aTokens the interest accrued is reflected in the aToken balance
    function _getMaxWithdrawableUnderlyingAssets() internal view override returns (uint256) {
        return totalAssets();
    }
}
