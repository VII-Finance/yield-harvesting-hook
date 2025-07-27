// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {
    IERC4626,
    IERC20,
    ERC4626Upgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

/**
 * @notice This vault wrapper is intended for use with lending protocol vaults where the underlying vault share price monotonically increases.
 * @dev If the underlying vault share price drops, this vault may become insolvent. In cases of bad debt socialization within the lending protocol vaults, the share price can decrease.
 *      It is recommended to have an insurance fund capable of burning tokens to restore solvency if needed.
 *      No harvest operations will occur until the vault regains solvency.
 */
contract ERC4626VaultWrapper is ERC4626Upgradeable {
    address public immutable yieldHarvestingHook;

    error NotYieldHarvester();

    constructor(address _yieldHarvestingHook) {
        yieldHarvestingHook = _yieldHarvestingHook;
    }

    function initialize(address _underlyingVault, string memory _name, string memory _symbol) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(IERC20(_underlyingVault));
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function underlyingVault() public view returns (IERC4626) {
        return IERC4626(asset());
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return underlyingVault().previewWithdraw(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return underlyingVault().previewMint(assets);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return underlyingVault().previewRedeem(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return underlyingVault().previewDeposit(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return underlyingVault().convertToAssets(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return underlyingVault().convertToShares(shares);
    }

    function maxDeposit(address) public view override returns (uint256) {
        return underlyingVault().maxMint(address(this));
    }

    function maxMint(address) public view override returns (uint256) {
        return underlyingVault().maxDeposit(address(this));
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return min(underlyingVault().maxWithdraw(address(this)), balanceOf(owner));
    }

    function pendingYield() public view returns (uint256) {
        uint256 maxWithdrawableAssets = underlyingVault().maxWithdraw(address(this));
        uint256 currentSupply = totalSupply();
        if (maxWithdrawableAssets > currentSupply) {
            return maxWithdrawableAssets - currentSupply;
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
