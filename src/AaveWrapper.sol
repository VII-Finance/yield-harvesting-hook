// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {
    IERC20,
    Math,
    ERC4626Upgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

/**
 * @notice This wrapper is intended for use with Aave's monotonically increasing aTokens.
 * @dev Aave does not have bad debt socialization, so this wrapper will always remain solvent.
 */
contract AaveWrapper is ERC4626Upgradeable {
    address public immutable yieldHarvestingHook;

    error NotYieldHarvester();

    constructor(address _yieldHarvestingHook) {
        yieldHarvestingHook = _yieldHarvestingHook;
    }

    function initialize(address _underlyingAToken, string memory _name, string memory _symbol) public initializer {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(IERC20(_underlyingAToken));
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function underlyingAToken() public view returns (IERC20) {
        return IERC20(asset());
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    //implement maxDeposit, maxMint, maxWithdraw, and maxRedeem depending on the specific aave logic

    function pendingYield() public view returns (uint256) {
        uint256 maxWithdrawableAssets = maxWithdraw(address(this));
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
