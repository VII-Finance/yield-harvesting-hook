// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {FullMath} from "lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol";

contract MockERC4626 is ERC4626 {
    constructor(MockERC20 asset) ERC4626(asset, "Mock ERC4626", "MERC4626") {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // solmate ERC4626 does not have phantom overflow protection
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : FullMath.mulDiv(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : FullMath.mulDiv(shares, totalAssets(), supply);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : FullMath.mulDivRoundingUp(shares, totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : FullMath.mulDivRoundingUp(assets, supply, totalAssets());
    }
}
