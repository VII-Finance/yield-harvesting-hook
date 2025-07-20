// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

contract ERC4626VaultWrapper is ERC4626 {
    using SafeTransferLib for ERC20;

    ERC4626 public immutable underlyingVault;
    address public immutable yieldHarvester;
    uint256 public immutable unitOfAssets;

    uint256 public sharePriceAtLastHarvest;

    error NotYieldHarvester();

    constructor(ERC4626 _vault, address _harvester, string memory _name, string memory _symbol)
        ERC4626(_vault.asset(), _name, _symbol)
    {
        underlyingVault = _vault;
        yieldHarvester = _harvester;
        unitOfAssets = 10 ** _vault.asset().decimals();
        _vault.asset().safeApprove(address(_vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public pure override returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) public pure override returns (uint256) {
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view override returns (uint256) {
        return underlyingVault.maxDeposit(address(this));
    }

    function maxMint(address) public view override returns (uint256) {
        return underlyingVault.maxMint(address(this));
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return min(underlyingVault.maxWithdraw(address(this)), balanceOf[owner]);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return maxWithdraw(owner);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 assets, uint256) internal override {
        underlyingVault.withdraw(assets, address(this), address(this));
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        underlyingVault.deposit(assets, address(this));
    }

    function pendingYield() public view returns (uint256) {
        return underlyingVault.maxWithdraw(address(this)) - totalSupply;
    }

    function harvest(address to) external returns (uint256 harvestedAssets) {
        if (msg.sender != yieldHarvester) revert NotYieldHarvester();
        harvestedAssets = pendingYield();
        _mint(to, harvestedAssets);
    }
}
