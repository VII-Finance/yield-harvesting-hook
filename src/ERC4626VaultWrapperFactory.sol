// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/VaultWrappers/ERC4626VaultWrapper.sol";
import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AaveWrapper} from "src/VaultWrappers/AaveWrapper.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

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
        vaultWrapperImplementation = address(new ERC4626VaultWrapper());
        aaveWrapperImplementation = address(new AaveWrapper());
    }

    function _generateSalt(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(tokenA, tokenB, fee, tickSpacing));
    }

    function _deployVaultWrapper(IERC4626 vault, bytes32 salt) internal returns (ERC4626VaultWrapper wrapper) {
        wrapper = ERC4626VaultWrapper(
            LibClone.cloneDeterministic(
                vaultWrapperImplementation, abi.encodePacked(address(this), yieldHarvestingHook, address(vault)), salt
            )
        );
    }

    function _deployAaveWrapper(address aToken, bytes32 salt) internal returns (AaveWrapper wrapper) {
        wrapper = AaveWrapper(
            LibClone.cloneDeterministic(
                aaveWrapperImplementation, abi.encodePacked(address(this), yieldHarvestingHook, aToken, aavePool), salt
            )
        );
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

    function createERC4626VaultPool(
        IERC4626 underlyingVaultA,
        IERC4626 underlyingVaultB,
        uint24 fee,
        int24 tickSpacing,
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

    function createERC4626VaultToTokenPool(
        IERC4626 underlyingVaultA,
        address assetB,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (ERC4626VaultWrapper vaultWrapper) {
        vaultWrapper =
            _deployVaultWrapper(underlyingVaultA, _generateSalt(address(underlyingVaultA), assetB, fee, tickSpacing));

        _initializePool(address(vaultWrapper), assetB, fee, tickSpacing, sqrtPriceX96);
    }

    function createAaveToERC4626Pool(
        address aToken,
        IERC4626 underlyingVault,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (AaveWrapper aaveWrapper, ERC4626VaultWrapper vaultWrapper) {
        aaveWrapper = _deployAaveWrapper(aToken, _generateSalt(aToken, address(underlyingVault), fee, tickSpacing));

        vaultWrapper =
            _deployVaultWrapper(underlyingVault, _generateSalt(address(underlyingVault), aToken, fee, tickSpacing));

        _initializePool(address(aaveWrapper), address(vaultWrapper), fee, tickSpacing, sqrtPriceX96);
    }

    function createAaveToTokenPool(address aToken, address asset, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (AaveWrapper aaveWrapper)
    {
        aaveWrapper = _deployAaveWrapper(aToken, _generateSalt(aToken, asset, fee, tickSpacing));

        _initializePool(address(aaveWrapper), asset, fee, tickSpacing, sqrtPriceX96);
    }

    function createAavePool(address aTokenA, address aTokenB, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (AaveWrapper aaveWrapperA, AaveWrapper aaveWrapperB)
    {
        aaveWrapperA = _deployAaveWrapper(aTokenA, _generateSalt(aTokenA, aTokenB, fee, tickSpacing));

        aaveWrapperB = _deployAaveWrapper(aTokenB, _generateSalt(aTokenB, aTokenA, fee, tickSpacing));

        _initializePool(address(aaveWrapperA), address(aaveWrapperB), fee, tickSpacing, sqrtPriceX96);
    }

    function configureWrapperFees(address vaultWrapper, uint256 feeDivisor, address feeReceiver) external onlyOwner {
        BaseVaultWrapper(vaultWrapper).setFeeParameters(feeDivisor, feeReceiver);
    }
}
