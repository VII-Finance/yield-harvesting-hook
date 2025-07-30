// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {BaseVaultWrapper} from "src/BaseVaultWrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Clones} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AaveWrapper} from "src/AaveWrapper.sol";
import {Ownable} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {console} from "forge-std/console.sol";

contract ERC4626VaultWrapperFactory is Ownable {
    IPoolManager public immutable poolManager;
    address public immutable yieldHarvestingHook;
    address public immutable vaultWrapperImplementation;
    address public immutable aaveWrapperImplementation;
    address public immutable aavePool;

    constructor(address _owner, IPoolManager _manager, address _yieldHarvestingHook, address _aavePool)
        Ownable(_owner)
    {
        poolManager = _manager;
        yieldHarvestingHook = _yieldHarvestingHook;
        aavePool = _aavePool;
        vaultWrapperImplementation = address(new ERC4626VaultWrapper(_yieldHarvestingHook));
        aaveWrapperImplementation = address(new AaveWrapper(_yieldHarvestingHook, _aavePool));
    }

    function getWrapperName(IERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII Finance Wrapped ", vault.name()));
    }

    function getWrapperSymbol(IERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII-", vault.symbol()));
    }

    function getAaveWrapperName(address aToken) public view returns (string memory) {
        return string(abi.encodePacked("VII Finance Aave Wrapped ", IERC4626(aToken).name()));
    }

    function getAaveWrapperSymbol(address aToken) public view returns (string memory) {
        return string(abi.encodePacked("VII-A-", IERC4626(aToken).symbol()));
    }

    function _generateSalt(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(tokenA, tokenB, fee, tickSpacing));
    }

    function _deployVaultWrapper(IERC4626 vault, bytes32 salt) internal returns (ERC4626VaultWrapper wrapper) {
        wrapper = ERC4626VaultWrapper(Clones.cloneDeterministic(vaultWrapperImplementation, salt));
        wrapper.initialize(address(vault), getWrapperName(vault), getWrapperSymbol(vault));
    }

    function _deployAaveWrapper(address aToken, bytes32 salt) internal returns (AaveWrapper wrapper) {
        wrapper = AaveWrapper(Clones.cloneDeterministic(aaveWrapperImplementation, salt));
        wrapper.initialize(aToken, getAaveWrapperName(aToken), getAaveWrapperSymbol(aToken));
    }

    function _initializePool(address currency0, address currency1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
    {
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(yieldHarvestingHook))
        });

        poolManager.initialize(poolKey, sqrtPriceX96);
    }

    function initializeVaultToVaultPool(
        uint24 fee,
        int24 tickSpacing,
        IERC4626 underlyingVaultA,
        IERC4626 underlyingVaultB,
        uint160 sqrtPriceX96
    ) external returns (ERC4626VaultWrapper vaultWrapperA, ERC4626VaultWrapper vaultWrapperB) {
        vaultWrapperA = _deployVaultWrapper(
            underlyingVaultA, _generateSalt(address(underlyingVaultA), address(underlyingVaultB), fee, tickSpacing)
        );

        vaultWrapperB = _deployVaultWrapper(
            underlyingVaultB, _generateSalt(address(underlyingVaultB), address(underlyingVaultA), fee, tickSpacing)
        );

        _initializePool(address(vaultWrapperA), address(vaultWrapperB), fee, tickSpacing, sqrtPriceX96);
    }

    function initializeVaultToTokenPool(
        uint24 fee,
        int24 tickSpacing,
        IERC4626 underlyingVaultA,
        address assetB,
        uint160 sqrtPriceX96
    ) external returns (ERC4626VaultWrapper vaultWrapper) {
        vaultWrapper =
            _deployVaultWrapper(underlyingVaultA, _generateSalt(address(underlyingVaultA), assetB, fee, tickSpacing));

        _initializePool(address(vaultWrapper), assetB, fee, tickSpacing, sqrtPriceX96);
    }

    function initializeAaveToVaultPool(
        uint24 fee,
        int24 tickSpacing,
        address aToken,
        IERC4626 underlyingVault,
        uint160 sqrtPriceX96
    ) external returns (AaveWrapper aaveWrapper, ERC4626VaultWrapper vaultWrapper) {
        aaveWrapper = _deployAaveWrapper(aToken, _generateSalt(aToken, address(underlyingVault), fee, tickSpacing));

        vaultWrapper =
            _deployVaultWrapper(underlyingVault, _generateSalt(address(underlyingVault), aToken, fee, tickSpacing));

        _initializePool(address(aaveWrapper), address(vaultWrapper), fee, tickSpacing, sqrtPriceX96);
    }

    function initializeAaveToTokenPool(
        uint24 fee,
        int24 tickSpacing,
        address aToken,
        address asset,
        uint160 sqrtPriceX96
    ) external returns (AaveWrapper aaveWrapper) {
        aaveWrapper = _deployAaveWrapper(aToken, _generateSalt(aToken, asset, fee, tickSpacing));

        _initializePool(address(aaveWrapper), asset, fee, tickSpacing, sqrtPriceX96);
    }

    function initializeAaveToAavePool(
        uint24 fee,
        int24 tickSpacing,
        address aTokenA,
        address aTokenB,
        uint160 sqrtPriceX96
    ) external returns (AaveWrapper aaveWrapperA, AaveWrapper aaveWrapperB) {
        aaveWrapperA = _deployAaveWrapper(aTokenA, _generateSalt(aTokenA, aTokenB, fee, tickSpacing));

        aaveWrapperB = _deployAaveWrapper(aTokenB, _generateSalt(aTokenB, aTokenA, fee, tickSpacing));

        _initializePool(address(aaveWrapperA), address(aaveWrapperB), fee, tickSpacing, sqrtPriceX96);
    }

    function setVaultWrapperFees(address vaultWrapper, uint256 feeDivisor, address feeReceiver) external onlyOwner {
        BaseVaultWrapper(vaultWrapper).setFeeParameters(feeDivisor, feeReceiver);
    }
}
