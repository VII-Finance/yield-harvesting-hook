// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Clones} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {console} from "forge-std/console.sol";

contract ERC4626VaultWrapperFactory {
    IPoolManager public immutable poolManager;
    address public immutable yieldHarvestingHook;
    address public immutable vaultWrapperImplementation;

    constructor(IPoolManager _manager, address _yieldHarvestingHook) {
        poolManager = _manager;
        yieldHarvestingHook = _yieldHarvestingHook;
        vaultWrapperImplementation = address(new ERC4626VaultWrapper(_yieldHarvestingHook));
    }

    function getWrapperName(IERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII Finance Wrapped ", vault.name()));
    }

    function getWrapperSymbol(IERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII-", vault.symbol()));
    }

    function initializePoolForTwoVault(
        uint24 fee,
        int24 tickSpacing,
        IERC4626 underlyingVaultA,
        IERC4626 underlyingVaultB,
        uint160 sqrtPriceX96
    ) external returns (ERC4626VaultWrapper vaultWrapperA, ERC4626VaultWrapper vaultWrapperB) {
        vaultWrapperA = ERC4626VaultWrapper(
            Clones.cloneDeterministic(
                vaultWrapperImplementation,
                keccak256(abi.encodePacked(address(underlyingVaultA), address(underlyingVaultB), fee, tickSpacing))
            )
        );

        vaultWrapperA.initialize(
            address(underlyingVaultA), getWrapperName(underlyingVaultA), getWrapperSymbol(underlyingVaultA)
        );

        vaultWrapperB = ERC4626VaultWrapper(
            Clones.cloneDeterministic(
                vaultWrapperImplementation,
                keccak256(abi.encodePacked(address(underlyingVaultB), address(underlyingVaultA), fee, tickSpacing))
            )
        );
        vaultWrapperB.initialize(
            address(underlyingVaultB), getWrapperName(underlyingVaultB), getWrapperSymbol(underlyingVaultB)
        );

        (ERC4626VaultWrapper vaultWrapper0, ERC4626VaultWrapper vaultWrapper1) =
            vaultWrapperA < vaultWrapperB ? (vaultWrapperA, vaultWrapperB) : (vaultWrapperB, vaultWrapperA);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(yieldHarvestingHook))
        });

        poolManager.initialize(poolKey, sqrtPriceX96);
    }

    function initializePoolForVaultAndAsset(
        uint24 fee,
        int24 tickSpacing,
        IERC4626 underlyingVaultA,
        address assetB,
        uint160 sqrtPriceX96
    ) external {
        address vaultWrapperA = Clones.cloneDeterministic(
            vaultWrapperImplementation, keccak256(abi.encodePacked(address(underlyingVaultA), assetB, fee, tickSpacing))
        );
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(vaultWrapperA),
            currency1: Currency.wrap(assetB),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(yieldHarvestingHook))
        });

        poolManager.initialize(poolKey, sqrtPriceX96);
    }
}
