// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {YieldHarvestingHookTest} from "test/YieldHarvestingHook.t.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

import {console} from "forge-std/console.sol";

contract Handler is YieldHarvestingHookTest {
    using StateLibrary for PoolManager;

    struct PositionInfo {
        int24 tickLower;
        int24 tickUpper;
    }

    address[] public actors;
    address internal currentActor;

    mapping(address => PositionInfo[]) public actorPositions;

    PoolId internal poolId;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        setUpVaults(false);
        poolId = poolKey.toId();

        for (uint256 i = 0; i < 10; i++) {
            address actor = makeAddr(string(abi.encodePacked("Actor ", i)));
            actors.push(actor);
            vm.label(actor, string(abi.encode("Actor ", i)));
        }
    }

    function getLiquidityGross(int24 tick) internal view returns (uint128 liquidityGross) {
        (liquidityGross,,,) = poolManager.getTickInfo(poolId, tick);
    }

    // the createFuzzyLiquidityParams in the Fuzzers library does not support multiple actors
    // getLiquidityDeltaFromAmounts has the checks to make sure the resulting liquidity amounts do not exceed type(uint128).max when
    // adding liquidity
    function createFuzzyLiquidityParams(ModifyLiquidityParams memory params, int24 tickSpacing_, uint160 sqrtPriceX96)
        internal
        view
        returns (ModifyLiquidityParams memory)
    {
        (params.tickLower, params.tickUpper) = boundTicks(params.tickLower, params.tickUpper, tickSpacing_);
        int256 liquidityDeltaFromAmounts =
            getLiquidityDeltaFromAmounts(params.tickLower, params.tickUpper, sqrtPriceX96);

        int256 liquidityMaxPerTick = int256(uint256(Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing_)));

        int256 liquidityMax =
            liquidityDeltaFromAmounts > liquidityMaxPerTick ? liquidityMaxPerTick : liquidityDeltaFromAmounts;

        //We read the current liquidity for the tickLower and tickUpper and make sure the resulting liquidity does not exceed the max liquidity per tick
        uint128 liquidityGrossTickLower = getLiquidityGross(params.tickLower);
        uint128 liquidityGrossTickUpper = getLiquidityGross(params.tickUpper);

        uint128 liquidityGrossTickLowerAfter = liquidityGrossTickLower + uint128(uint256(liquidityMax));

        if (liquidityGrossTickLowerAfter > uint128(uint256(liquidityMaxPerTick))) {
            liquidityMax = int256(uint256(liquidityMaxPerTick) - uint256(liquidityGrossTickLower));
        }
        uint128 liquidityGrossTickUpperAfter = liquidityGrossTickUpper + uint128(uint256(liquidityMax));

        if (liquidityGrossTickUpperAfter > uint128(uint256(liquidityMaxPerTick))) {
            liquidityMax = int256(uint256(liquidityMaxPerTick) - uint256(liquidityGrossTickUpper));
        }

        _vm.assume(liquidityMax != 0);
        params.liquidityDelta = bound(liquidityDeltaFromAmounts, 1, liquidityMax);

        return params;
    }

    function addLiquidity(uint256 actorIndexSeed, ModifyLiquidityParams memory params)
        external
        useActor(actorIndexSeed)
    {
        params.salt = bytes32(uint256(uint160(currentActor)));
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);
        // params.liquidityDelta = bound(params.liquidityDelta, 1, 10_000);

        // params.tickLower = 0;
        // params.tickUpper = 60;

        params = createFuzzyLiquidityParams(params, poolKey.tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        directMintVaultWrapper(address(vaultWrapper0), estimatedAmount0Required * 2 + 1);
        directMintVaultWrapper(address(vaultWrapper1), estimatedAmount1Required * 2 + 1);

        IERC20(address(vaultWrapper0)).approve(address(modifyLiquidityRouter), estimatedAmount0Required * 2 + 1);
        IERC20(address(vaultWrapper1)).approve(address(modifyLiquidityRouter), estimatedAmount1Required * 2 + 1);

        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "", false, false);

        actorPositions[currentActor].push(PositionInfo({tickLower: params.tickLower, tickUpper: params.tickUpper}));
    }

    // no clamping
    function directMintUnderlyingVault(address underlyingVault, uint256 amount) internal {
        address underlyingAsset = IERC4626(underlyingVault).asset();
        uint256 underlyingAssetsNeeded = IERC4626(underlyingVault).previewMint(amount);

        MockERC20(underlyingAsset).mint(currentActor, underlyingAssetsNeeded);
        IERC20(underlyingAsset).approve(underlyingVault, underlyingAssetsNeeded);

        IERC4626(underlyingVault).mint(amount, currentActor);
    }

    // no clamping
    function directMintVaultWrapper(address vaultWrapper, uint256 amount) internal {
        address underlyingVault = IERC4626(vaultWrapper).asset();
        uint256 underlyingVaultSharesNeeded = IERC4626(vaultWrapper).previewMint(amount);

        directMintUnderlyingVault(underlyingVault, underlyingVaultSharesNeeded);

        IERC20(underlyingVault).approve(vaultWrapper, underlyingVaultSharesNeeded);
        IERC4626(vaultWrapper).mint(amount, currentActor);
    }

    function directDepositUnderlyingVault(address underlyingVault, uint256 amount) internal {
        address underlyingAsset = IERC4626(underlyingVault).asset();

        // we do this to avoid ZERO_ASSETS error in case amount is very small
        uint256 assetsRequiredToMint1Share = IERC4626(underlyingVault).previewMint(1);
        amount = amount < assetsRequiredToMint1Share ? assetsRequiredToMint1Share : amount;

        MockERC20(underlyingAsset).mint(currentActor, amount);
        IERC20(underlyingAsset).approve(underlyingVault, amount);

        IERC4626(underlyingVault).deposit(amount, currentActor);
    }

    function directDepositVaultWrapper(address vaultWrapper, uint256 amount) internal {
        address underlyingVault = IERC4626(vaultWrapper).asset();
        uint256 underlyingVaultSharesNeeded = IERC4626(vaultWrapper).previewDeposit(amount);

        directMintUnderlyingVault(underlyingVault, underlyingVaultSharesNeeded);

        IERC20(underlyingVault).approve(vaultWrapper, underlyingVaultSharesNeeded);
        IERC4626(vaultWrapper).deposit(amount, currentActor);
    }

    // it has the clamping logic enabled
    function withdrawFromERC4626Vault(IERC4626 vault, uint256 amount) internal {
        uint256 maxWithdrawable = vault.maxWithdraw(currentActor);
        amount = bound(amount, 0, maxWithdrawable);

        uint256 expectedSharesToBurn = vault.previewWithdraw(amount);
        uint256 sharesBalanceBefore = vault.balanceOf(currentActor);

        vault.withdraw(amount, currentActor, currentActor);

        assertEq(vault.balanceOf(currentActor), sharesBalanceBefore - expectedSharesToBurn);
    }

    function redeemFromERC4626Vault(IERC4626 vault, uint256 amount) internal {
        amount = bound(amount, 0, vault.balanceOf(currentActor));

        //avoid ZERO_ASSETS error
        if (amount == 0) {
            return;
        }

        uint256 expectedAssetsToReceive = vault.previewRedeem(amount);
        uint256 assetBalanceBefore = IERC20(vault.asset()).balanceOf(currentActor);

        vault.redeem(amount, currentActor, currentActor);

        assertEq(IERC20(vault.asset()).balanceOf(currentActor), assetBalanceBefore + expectedAssetsToReceive);
    }

    function removeLiquidity(uint256 actorIndexSeed, uint256 positionIndexSeed, uint256 liquidityToRemove)
        external
        useActor(actorIndexSeed)
    {
        ModifyLiquidityParams memory params;
        params.salt = bytes32(uint256(uint160(currentActor)));
        {
            PositionInfo[] memory positions = actorPositions[currentActor];
            if (positions.length == 0) {
                return;
            }
            PositionInfo memory position = positions[bound(positionIndexSeed, 0, positions.length - 1)];
            params.tickLower = position.tickLower;
            params.tickUpper = position.tickUpper;

            // we get the current liquidity of the position to bound the liquidityToRemove
            (uint128 currentLiquidity,,) = poolManager.getPositionInfo(
                poolId, address(modifyLiquidityRouter), params.tickLower, params.tickUpper, params.salt
            );

            if (currentLiquidity == 0) {
                return;
            }

            params.liquidityDelta = -int256(uint256(bound(liquidityToRemove, 0, currentLiquidity)));
        }

        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "", false, false);
    }

    //TODO: add swaps as well
    function swap() external {}

    function mintIntoVaultWrapper(uint256 actorIndexSeed, bool isVaultWrapper0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        amount = bound(amount, 1, type(uint128).max / 2);
        directMintVaultWrapper(isVaultWrapper0 ? address(vaultWrapper0) : address(vaultWrapper1), amount);
    }

    function depositIntoVaultWrapper(uint256 actorIndexSeed, bool isVaultWrapper0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        amount = bound(amount, 1, type(uint128).max / 2);
        directDepositVaultWrapper(isVaultWrapper0 ? address(vaultWrapper0) : address(vaultWrapper1), amount);
    }

    function withdrawFromVaultWrapper(uint256 actorIndexSeed, bool isVaultWrapper0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        IERC4626 vaultWrapper = isVaultWrapper0 ? IERC4626(address(vaultWrapper0)) : IERC4626(address(vaultWrapper1));
        withdrawFromERC4626Vault(vaultWrapper, amount);
    }

    function redeemFromVaultWrapper(uint256 actorIndexSeed, bool isVaultWrapper0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        IERC4626 vaultWrapper = isVaultWrapper0 ? IERC4626(address(vaultWrapper0)) : IERC4626(address(vaultWrapper1));
        redeemFromERC4626Vault(vaultWrapper, amount);
    }

    function mintIntoUnderlyingVault(uint256 actorIndexSeed, bool isVault0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        amount = bound(amount, 1, type(uint128).max / 2);
        directMintUnderlyingVault(isVault0 ? address(underlyingVault0) : address(underlyingVault1), amount);
    }

    function depositIntoUnderlyingVault(uint256 actorIndexSeed, bool isVault0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        amount = bound(amount, 1, type(uint128).max / 2);
        directDepositUnderlyingVault(isVault0 ? address(underlyingVault0) : address(underlyingVault1), amount);
    }

    function withdrawFromUnderlyingVault(uint256 actorIndexSeed, bool isVault0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        IERC4626 underlyingVault = isVault0 ? IERC4626(address(underlyingVault0)) : IERC4626(address(underlyingVault1));
        withdrawFromERC4626Vault(underlyingVault, amount);
    }

    function redeemFromUnderlyingVault(uint256 actorIndexSeed, bool isVault0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        IERC4626 underlyingVault = isVault0 ? IERC4626(address(underlyingVault0)) : IERC4626(address(underlyingVault1));
        redeemFromERC4626Vault(underlyingVault, amount);
    }

    // accrue some yield to the underlying vault by donating underlying assets
    function donateToUnderlyingVault(bool isVault0, uint256 amount) external {
        amount = bound(amount, 1, type(uint32).max); // trying be conservative to avoid overflows

        IERC4626 underlyingVault = isVault0 ? IERC4626(address(underlyingVault0)) : IERC4626(address(underlyingVault1));
        address underlyingAsset = underlyingVault.asset();

        // mint underlying assets and deposit directly into the underlying vault
        MockERC20(underlyingAsset).mint(address(underlyingVault), amount);
    }

    //anyone can directly donate underlying vault shares to vault wrappers and it should count as yield as well
    function donateToVaultWrapper(uint256 actorIndexSeed, bool isVault0, uint256 amount)
        external
        useActor(actorIndexSeed)
    {
        amount = bound(amount, 1, type(uint32).max); // trying be conservative to avoid overflows

        address underlyingVault = isVault0 ? address(underlyingVault0) : address(underlyingVault1);
        address vaultWrapper = isVault0 ? address(vaultWrapper0) : address(vaultWrapper1);

        directMintUnderlyingVault(underlyingVault, amount);

        IERC20(underlyingVault).transfer(vaultWrapper, amount);
    }

    // TODO: add handlers to realize loss in a vault
}
