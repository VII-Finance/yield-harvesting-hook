// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626} from "solmate/src/mixins/ERC4626.sol";

/**
 * @notice This vault wrapper is intended for use with lending protocol vaults where the underlying vault share price monotonically increases.
 * @dev If the underlying vault share price drops, this vault may become insolvent. In cases of bad debt socialization within the lending protocol vaults, the share price can decrease.
 *      It is recommended to have an insurance fund capable of burning tokens to restore solvency if needed.
 *      No harvest operations will occur until the vault regains solvency.
 */
contract ERC4626VaultWrapper is ERC4626 {
    address public immutable yieldHarvestingHook;

    error NotYieldHarvester();

    constructor(ERC4626 _underlyingVault, address _yieldHarvestingHook, string memory _name, string memory _symbol)
        ERC4626(_underlyingVault, _name, _symbol)
    {
        yieldHarvestingHook = _yieldHarvestingHook;
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).previewWithdraw(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).previewMint(assets);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).previewRedeem(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).previewDeposit(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).convertToAssets(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).convertToShares(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view override returns (uint256) {
        return ERC4626(address(asset)).maxMint(address(this));
    }

    function maxMint(address) public view override returns (uint256) {
        return ERC4626(address(asset)).maxDeposit(address(this));
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return min(ERC4626(address(asset)).maxWithdraw(address(this)), balanceOf[owner]);
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST YIELD LOGIC
    //////////////////////////////////////////////////////////////*/

    function pendingYield() public view returns (uint256) {
        uint256 maxWithdrawableAssets = ERC4626(address(asset)).maxWithdraw(address(this));
        if (maxWithdrawableAssets > totalSupply) {
            return maxWithdrawableAssets - totalSupply;
        }
        return 0;
    }

    function harvest(address to) external returns (uint256 harvestedAssets) {
        if (msg.sender != yieldHarvestingHook) revert NotYieldHarvester();
        harvestedAssets = pendingYield();
        if (harvestedAssets > 0) _mint(to, harvestedAssets);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
