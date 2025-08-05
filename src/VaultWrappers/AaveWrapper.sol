// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC20, Math} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";
import {DataTypes as AaveDataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";

import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";

interface IATokenWithPool is IAToken {
    //This method is exposed by actual aTokens but it isn't in IAToken interface
    function POOL() external view returns (address);
}

/**
 * @notice This wrapper is intended for use with Aave's monotonically increasing aTokens.
 * @dev Aave does not have bad debt socialization, so this wrapper will always remain solvent.
 */
contract AaveWrapper is BaseVaultWrapper {
    uint256 constant AAVE_ACTIVE_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFF;
    uint256 constant AAVE_FROZEN_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDFFFFFFFFFFFFFF;
    uint256 constant AAVE_PAUSED_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFFF;
    uint256 constant AAVE_SUPPLY_CAP_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFF000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint256 constant AAVE_SUPPLY_CAP_BIT_POSITION = 116;

    constructor() BaseVaultWrapper() {}

    function getAavePool() public view returns (IPool) {
        return IPool(IATokenWithPool(asset()).POOL());
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function underlyingAToken() public view returns (IAToken) {
        return IAToken(asset());
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return _maxAssetsSuppliableToAave();
    }

    function maxMint(address) public view override returns (uint256) {
        return _maxAssetsSuppliableToAave();
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(_maxAssetsWithdrawableFromAave(), balanceOf(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return maxWithdraw(owner);
    }

    function _maxAssetsSuppliableToAave() internal view virtual returns (uint256) {
        // returns 0 if reserve is not active, frozen, or paused
        // returns max uint256 value if supply cap is 0 (not capped)
        // returns supply cap - current amount supplied as max suppliable if there is a supply cap for this reserve

        AaveDataTypes.ReserveData memory reserveData =
            getAavePool().getReserveData(underlyingAToken().UNDERLYING_ASSET_ADDRESS());

        uint256 reserveConfigMap = reserveData.configuration.data;
        uint256 supplyCap = (reserveConfigMap & ~AAVE_SUPPLY_CAP_MASK) >> AAVE_SUPPLY_CAP_BIT_POSITION;

        if (
            (reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) || (reserveConfigMap & ~AAVE_FROZEN_MASK != 0)
                || (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)
        ) {
            return 0;
        } else if (supplyCap == 0) {
            return type(uint256).max;
        } else {
            // Reserve's supply cap - current amount supplied
            // See similar logic in Aave v3 ValidationLogic library, in the validateSupply function
            // https://github.com/aave/aave-v3-core/blob/a00f28e3ad7c0e4a369d8e06e0ac9fd0acabcab7/contracts/protocol/libraries/logic/ValidationLogic.sol#L71-L78
            uint256 currentSupply = WadRayMath.rayMul(
                (underlyingAToken().scaledTotalSupply() + uint256(reserveData.accruedToTreasury)),
                reserveData.liquidityIndex
            );
            uint256 supplyCapWithDecimals = supplyCap * 10 ** decimals();
            return supplyCapWithDecimals > currentSupply ? supplyCapWithDecimals - currentSupply : 0;
        }
    }

    function _maxAssetsWithdrawableFromAave() internal view virtual returns (uint256) {
        // returns 0 if reserve is not active, or paused
        // otherwise, returns available liquidity

        AaveDataTypes.ReserveData memory reserveData =
            getAavePool().getReserveData(underlyingAToken().UNDERLYING_ASSET_ADDRESS());

        uint256 reserveConfigMap = reserveData.configuration.data;

        if ((reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) || (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)) {
            return 0;
        } else {
            return IERC20(underlyingAToken().UNDERLYING_ASSET_ADDRESS()).balanceOf(asset());
        }
    }

    function _getMaxWithdrawableUnderlyingAssets() internal view override returns (uint256) {
        return underlyingAToken().balanceOf(address(this));
    }
}
