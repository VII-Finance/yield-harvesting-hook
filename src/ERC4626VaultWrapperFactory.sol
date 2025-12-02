// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/vaultWrappers/ERC4626VaultWrapper.sol";
import {BaseVaultWrapper} from "src/vaultWrappers/base/BaseVaultWrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AaveWrapper} from "src/vaultWrappers/AaveWrapper.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @notice The factory does not perform strict sanity checks on the provided addresses to ensure they match the expected types.
/// For example, if a user inputs an ERC4626 vault address where an aToken is expected, or a token address where an ERC4626 vault is expected, the pool will still be created, but it will be invalid.
/// Pool deployment is permissionless, so some invalid pools are expected. Basic sanity checks could be added, such as if calling the `asset()` method on an ERC4626 vault address fails it's not an ERC4626 Vault.
/// However, this does not guarantee the vault strictly adheres to the ERC4626 standard, and we cannot check everything required by the protocol anyway.
/// Users must ensure that the vault wrappers they deposit into have the correct underlying assets and conform to the expected standards.
contract ERC4626VaultWrapperFactory is Ownable {
    IPoolManager public immutable poolManager;
    address public immutable yieldHarvestingHook;
    address public immutable vaultWrapperImplementation;
    address public immutable aaveWrapperImplementation;

    constructor(address _owner, IPoolManager _manager, address _yieldHarvestingHook) Ownable(_owner) {
        poolManager = _manager;
        yieldHarvestingHook = _yieldHarvestingHook;
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

    function _deployVaultWrapper(address implementation, address underlyingVault, bytes32 salt)
        internal
        returns (address wrapper)
    {
        wrapper = LibClone.cloneDeterministic(
            implementation, abi.encodePacked(address(this), yieldHarvestingHook, underlyingVault), salt
        );
    }

    function _initializePool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
    {
        PoolKey memory poolKey = _buildPoolKey(tokenA, tokenB, fee, tickSpacing);
        poolManager.initialize(poolKey, sqrtPriceX96);
    }

    /**
     * @notice If someone front-runs the creation of the pool before user, user function call fails and that frontrunner can
     * set the initial price to whatever they want.
     * 1. If you are doing things atomically always make sure the pool is not already initialized before making the create call.
     * 2. Before adding liquidity always make sure the price of the pool is the right price and if not conduct the arbitrage
     * to bring the price to the right price.
     */
    function createERC4626VaultPool(
        IERC4626 underlyingVaultA,
        IERC4626 underlyingVaultB,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (ERC4626VaultWrapper vaultWrapperA, ERC4626VaultWrapper vaultWrapperB) {
        vaultWrapperA = ERC4626VaultWrapper(
            _deployVaultWrapper(
                vaultWrapperImplementation,
                address(underlyingVaultA),
                _generateSalt(address(underlyingVaultA), address(underlyingVaultB), fee, tickSpacing)
            )
        );

        vaultWrapperB = ERC4626VaultWrapper(
            _deployVaultWrapper(
                vaultWrapperImplementation,
                address(underlyingVaultB),
                _generateSalt(address(underlyingVaultB), address(underlyingVaultA), fee, tickSpacing)
            )
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
        vaultWrapper = ERC4626VaultWrapper(
            _deployVaultWrapper(
                vaultWrapperImplementation,
                address(underlyingVaultA),
                _generateSalt(address(underlyingVaultA), assetB, fee, tickSpacing)
            )
        );

        _initializePool(address(vaultWrapper), assetB, fee, tickSpacing, sqrtPriceX96);
    }

    function createAaveToERC4626Pool(
        address aToken,
        IERC4626 underlyingVault,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (AaveWrapper aaveWrapper, ERC4626VaultWrapper vaultWrapper) {
        aaveWrapper = AaveWrapper(
            _deployVaultWrapper(
                aaveWrapperImplementation, aToken, _generateSalt(aToken, address(underlyingVault), fee, tickSpacing)
            )
        );

        vaultWrapper = ERC4626VaultWrapper(
            _deployVaultWrapper(
                vaultWrapperImplementation,
                address(underlyingVault),
                _generateSalt(address(underlyingVault), aToken, fee, tickSpacing)
            )
        );

        _initializePool(address(aaveWrapper), address(vaultWrapper), fee, tickSpacing, sqrtPriceX96);
    }

    function createAaveToTokenPool(address aToken, address asset, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (AaveWrapper aaveWrapper)
    {
        aaveWrapper = AaveWrapper(
            _deployVaultWrapper(aaveWrapperImplementation, aToken, _generateSalt(aToken, asset, fee, tickSpacing))
        );

        _initializePool(address(aaveWrapper), asset, fee, tickSpacing, sqrtPriceX96);
    }

    function createAavePool(address aTokenA, address aTokenB, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (AaveWrapper aaveWrapperA, AaveWrapper aaveWrapperB)
    {
        aaveWrapperA = AaveWrapper(
            _deployVaultWrapper(aaveWrapperImplementation, aTokenA, _generateSalt(aTokenA, aTokenB, fee, tickSpacing))
        );

        aaveWrapperB = AaveWrapper(
            _deployVaultWrapper(aaveWrapperImplementation, aTokenB, _generateSalt(aTokenB, aTokenA, fee, tickSpacing))
        );

        _initializePool(address(aaveWrapperA), address(aaveWrapperB), fee, tickSpacing, sqrtPriceX96);
    }

    function setWrapperFeeParameters(address vaultWrapper, uint256 feeDivisor, address feeReceiver) external onlyOwner {
        BaseVaultWrapper(vaultWrapper).setFeeParameters(feeDivisor, feeReceiver);
    }

    function predictERC4626VaultPoolKey(
        IERC4626 underlyingVaultA,
        IERC4626 underlyingVaultB,
        uint24 fee,
        int24 tickSpacing
    ) external view returns (PoolKey memory poolKey) {
        address wrapperA = _predictVaultWrapperAddress(
            vaultWrapperImplementation, address(underlyingVaultA), address(underlyingVaultB), fee, tickSpacing
        );
        address wrapperB = _predictVaultWrapperAddress(
            vaultWrapperImplementation, address(underlyingVaultB), address(underlyingVaultA), fee, tickSpacing
        );

        return _buildPoolKey(wrapperA, wrapperB, fee, tickSpacing);
    }

    function predictERC4626VaultToTokenPoolKey(IERC4626 underlyingVault, address token, uint24 fee, int24 tickSpacing)
        external
        view
        returns (PoolKey memory poolKey)
    {
        address wrapper =
            _predictVaultWrapperAddress(vaultWrapperImplementation, address(underlyingVault), token, fee, tickSpacing);

        return _buildPoolKey(wrapper, token, fee, tickSpacing);
    }

    function predictAaveToERC4626PoolKey(address aToken, IERC4626 underlyingVault, uint24 fee, int24 tickSpacing)
        external
        view
        returns (PoolKey memory poolKey)
    {
        address aaveWrapper =
            _predictVaultWrapperAddress(aaveWrapperImplementation, aToken, address(underlyingVault), fee, tickSpacing);
        address vaultWrapper =
            _predictVaultWrapperAddress(vaultWrapperImplementation, address(underlyingVault), aToken, fee, tickSpacing);

        return _buildPoolKey(aaveWrapper, vaultWrapper, fee, tickSpacing);
    }

    function predictAaveToTokenPoolKey(address aToken, address token, uint24 fee, int24 tickSpacing)
        external
        view
        returns (PoolKey memory poolKey)
    {
        address aaveWrapper = _predictVaultWrapperAddress(aaveWrapperImplementation, aToken, token, fee, tickSpacing);

        return _buildPoolKey(aaveWrapper, token, fee, tickSpacing);
    }

    function predictAavePoolKey(address aTokenA, address aTokenB, uint24 fee, int24 tickSpacing)
        external
        view
        returns (PoolKey memory poolKey)
    {
        address aaveWrapperA =
            _predictVaultWrapperAddress(aaveWrapperImplementation, aTokenA, aTokenB, fee, tickSpacing);
        address aaveWrapperB =
            _predictVaultWrapperAddress(aaveWrapperImplementation, aTokenB, aTokenA, fee, tickSpacing);

        return _buildPoolKey(aaveWrapperA, aaveWrapperB, fee, tickSpacing);
    }

    function _predictVaultWrapperAddress(
        address implementation,
        address vault,
        address otherToken,
        uint24 fee,
        int24 tickSpacing
    ) internal view returns (address wrapperAddress) {
        bytes32 salt = _generateSalt(vault, otherToken, fee, tickSpacing);
        bytes memory immutableArgs = abi.encodePacked(address(this), yieldHarvestingHook, vault);

        return LibClone.predictDeterministicAddress(implementation, immutableArgs, salt, address(this));
    }

    function _buildPoolKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (PoolKey memory poolKey)
    {
        (address currency0, address currency1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(yieldHarvestingHook)
        });
    }
}
