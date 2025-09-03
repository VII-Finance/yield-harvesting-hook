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
        AssetToAssetSwapHookForERC4626(0x01cc8dC6c3f7f03e845B1F4d491Bdec975434088);
    LiquidityHelper liquidityHelper = LiquidityHelper(0x920E6cF9EbbfC5bCB2900A4998BD7a7BAa67a943);

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

        IERC4626 vault0 = IERC4626(0xA6be43F0505Da6e37B0805e1A0B7AaCb3065F0c8); //eUSDC
        IERC4626 vault1 = IERC4626(0xFeA428F58c678B3f14Fd750200bF14906F21e53c); //eUSDT0

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

        (ERC4626VaultWrapper vaultWrapper0, ERC4626VaultWrapper vaultWrapper1) = erc4626VaultWrapperFactory
            .createERC4626VaultPool(
            vault0,
            vault1,
            referenceAssetsPoolKey.fee,
            referenceAssetsPoolKey.tickSpacing,
            TickMath.getSqrtPriceAtTick(referencePoolTick)
        );

        bool isVaultWrapper0Currency0 = vaultWrapper0 < vaultWrapper1;

        require(isVaultWrapper0Currency0Predicted == isVaultWrapper0Currency0, "vault wrapper order mismatch");

        //let's also initialize assetToAssetSwapHook as well
        referenceAssetsPoolKey.hooks = IHooks(address(assetToAssetSwapHook));

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
            _currencyToIERC20(referenceAssetsPoolKey.currency0).allowance(msg.sender, address(liquidityHelper))
                < currency0AmountToAdd
        ) {
            _currencyToIERC20(referenceAssetsPoolKey.currency0).forceApprove(
                address(liquidityHelper), type(uint256).max
            );
        }
        if (
            _currencyToIERC20(referenceAssetsPoolKey.currency1).allowance(msg.sender, address(liquidityHelper))
                < currency1AmountToAdd
        ) {
            _currencyToIERC20(referenceAssetsPoolKey.currency1).forceApprove(
                address(liquidityHelper), type(uint256).max
            );
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
