// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626VaultWrapper} from "src/vaultWrappers/ERC4626VaultWrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AssetToAssetSwapHookForERC4626} from "src/periphery/AssetToAssetSwapHookForERC4626.sol";
import {LiquidityHelper} from "src/periphery/LiquidityHelper.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract CreatePoolsScript is Script {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    YieldHarvestingHook yieldHarvestingHook = YieldHarvestingHook(0x777ef319C338C6ffE32A2283F603db603E8F2A80);
    AssetToAssetSwapHookForERC4626 assetToAssetSwapHook =
        AssetToAssetSwapHookForERC4626(0x604E6C45FEe7D7634865603c37Ef1695D0f2C888);
    LiquidityHelper liquidityHelper = LiquidityHelper(0xc6E2e5E10D2793EFdee7A94080f333e653466fb8);

    function _currencyToIERC20(Currency currency) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(currency));
    }

    function run() external {
        ERC4626VaultWrapperFactory erc4626VaultWrapperFactory =
            ERC4626VaultWrapperFactory(yieldHarvestingHook.erc4626VaultWrapperFactory());

        PoolKey memory referenceAssetsPoolKey = PoolKey({
            currency0: Currency.wrap(0x078D782b760474a361dDA0AF3839290b0EF57AD6), // USDC
            currency1: Currency.wrap(0x9151434b16b9763660705744891fA906F660EcC5), // USDT0
            fee: 18,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        require(
            PoolId.unwrap(referenceAssetsPoolKey.toId())
                == 0xaf58ab3ed922b34e94d13e01edf1b4ddbe5d2afbc29abbcef5ef8ff752a1ae5a,
            "Invalid pool ID"
        );

        IPoolManager poolManager = yieldHarvestingHook.poolManager();

        (, int24 referencePoolTick,,) = poolManager.getSlot0(referenceAssetsPoolKey.toId());

        IERC4626 vault0 = IERC4626(0x6eAe95ee783e4D862867C4e0E4c3f4B95AA682Ba); //eUSDC
        IERC4626 vault1 = IERC4626(0xD49181c522eCDB265f0D9C175Cf26FFACE64eAD3); //eUSDT0

        require(vault0.asset() == Currency.unwrap(referenceAssetsPoolKey.currency0), "vault0 asset mismatch");
        require(vault1.asset() == Currency.unwrap(referenceAssetsPoolKey.currency1), "vault1 asset mismatch");

        PoolKey memory vaultsPoolKey = erc4626VaultWrapperFactory.predictERC4626VaultPoolKey(
            vault0, vault1, referenceAssetsPoolKey.fee, referenceAssetsPoolKey.tickSpacing
        );

        bool isVaultWrapper0Currency0Predicted = false;

        if (!isVaultWrapper0Currency0Predicted) {
            referencePoolTick = -referencePoolTick;
        }

        vm.startBroadcast();

        (ERC4626VaultWrapper vaultWrapper0, ERC4626VaultWrapper vaultWrapper1) = erc4626VaultWrapperFactory.createERC4626VaultPool(
            vault0,
            vault1,
            referenceAssetsPoolKey.fee,
            referenceAssetsPoolKey.tickSpacing,
            TickMath.getSqrtPriceAtTick(referencePoolTick)
        );

        // (ERC4626VaultWrapper vaultWrapper0, ERC4626VaultWrapper vaultWrapper1) = (ERC4626VaultWrapper(0xE1b1387ec4ac848f9B7A0E7750bCb330a2d390df), ERC4626VaultWrapper(0x868669425240F69e69BDBf152f42F8F8a5024882));

        bool isVaultWrapper0Currency0 = vaultWrapper0 < vaultWrapper1;

        require(isVaultWrapper0Currency0Predicted == isVaultWrapper0Currency0, "vault wrapper order mismatch");

        //let's also initialize assetToAssetSwapHook as well
        referenceAssetsPoolKey.hooks = IHooks(address(assetToAssetSwapHook));

        //set default vault wrappers in yield harvesting hook
        assetToAssetSwapHook.setDefaultVaultWrappers(referenceAssetsPoolKey, vaultWrapper0, vaultWrapper1);

        poolManager.initialize(referenceAssetsPoolKey, TickMath.getSqrtPriceAtTick(0));

        addLiquidity(
            5 * 1e6, 5 * 1e6, address(vaultWrapper0), address(vaultWrapper1), referencePoolTick, referenceAssetsPoolKey
        );

        vm.stopBroadcast();
    }

    function addLiquidity(
        uint128 currency0AmountToAdd,
        uint128 currency1AmountToAdd,
        address vaultWrapper0,
        address vaultWrapper1,
        int24 referencePoolTick,
        PoolKey memory referenceAssetsPoolKey
    ) public {
        if (
            _currencyToIERC20(referenceAssetsPoolKey.currency0)
                    .allowance(0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394, address(liquidityHelper))
                < currency0AmountToAdd
        ) {
            _currencyToIERC20(referenceAssetsPoolKey.currency0)
                .forceApprove(address(liquidityHelper), type(uint256).max);
        }
        if (
            _currencyToIERC20(referenceAssetsPoolKey.currency1)
                    .allowance(0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394, address(liquidityHelper))
                < currency1AmountToAdd
        ) {
            _currencyToIERC20(referenceAssetsPoolKey.currency1)
                .forceApprove(address(liquidityHelper), type(uint256).max);
        }

        liquidityHelper.mintPosition(
            referenceAssetsPoolKey,
            referencePoolTick - 60,
            referencePoolTick + 60,
            1000 * 1e6,
            currency0AmountToAdd,
            currency1AmountToAdd,
            msg.sender,
            abi.encode(vaultWrapper0, vaultWrapper1)
        );
    }
}
