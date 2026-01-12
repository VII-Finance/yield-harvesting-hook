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

    function directMintUnderlyingVault(address underlyingVault, uint256 amount) internal {
        address underlyingAsset = IERC4626(underlyingVault).asset();
        uint256 underlyingAssetsNeeded = IERC4626(underlyingVault).previewMint(amount);

        MockERC20(underlyingAsset).mint(currentActor, underlyingAssetsNeeded);
        IERC20(underlyingAsset).approve(underlyingVault, underlyingAssetsNeeded);

        IERC4626(underlyingVault).mint(amount, currentActor);
    }

    function directMintVaultWrapper(address vaultWrapper, uint256 amount) internal {
        address underlyingVault = IERC4626(vaultWrapper).asset();
        uint256 underlyingVaultSharesNeeded = IERC4626(vaultWrapper).previewMint(amount);

        directMintUnderlyingVault(underlyingVault, underlyingVaultSharesNeeded);

        IERC20(underlyingVault).approve(vaultWrapper, underlyingVaultSharesNeeded);
        IERC4626(vaultWrapper).mint(amount, currentActor);
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

    function swap() external {}

    function directMintVaultWrapper(uint256 actorIndexSeed, uint256 amount) external useActor(actorIndexSeed) {
        amount = bound(amount, 1, type(uint128).max / 2);
        directMintVaultWrapper(address(vaultWrapper0), amount);
    }

    function directWithdrawVaultWrapper(uint256 actorIndexSeed, uint256 amount) external useActor(actorIndexSeed) {
        // we get the max withdrawable amount for the actor
        uint256 maxWithdrawable = IERC4626(address(vaultWrapper0)).maxWithdraw(address(currentActor));
        amount = bound(amount, 0, maxWithdrawable);
        vaultWrapper0.withdraw(amount, currentActor, currentActor);
    }

    function directDepositToERC4626Vault() external {}

    function directWithdrawFromERC4626Vault(uint256 actorIndexSeed, uint256 amount) external {}

    function donateToERC4626Vault() external {}

    function reportLossForERC4626Vault() external {}

    function donateToVaultWrapper() external {}
}
