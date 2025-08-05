# VII Finance - Yield Harvesting Uniswap V4 Hook

> **Earn dual yield from trading fees AND lending interest while providing liquidity**

## Overview

VII Finance introduces a novel Uniswap V4 hook that allows liquidity providers to earn both traditional trading fees and interest from any lending protocol simultaneously.

The protocol achieves this by wrapping yield-bearing tokens (such as ERC4626 vault shares or Aave aTokens) into “VII Wrapped” tokens, which separate the principal from the interest. Before each liquidity add, remove, or swap, the hook donates the accrued interest to the pool, allowing active LPs to benefit from the interest on top of the swap fees.

### Smart Contracts

```
src/
├── YieldHarvestingHook.sol           # Main Uniswap V4 hook
├── ERC4626VaultWrapperFactory.sol    # Factory for creating pools
└── VaultWrappers/
    ├── Base/BaseVaultWrapper.sol     # Shared wrapper logic
    ├── ERC4626VaultWrapper.sol       # ERC4626 vault wrapper
    └── AaveWrapper.sol               # Aave aToken wrapper
```

## Usage Example

### Creating a Pool

```solidity
// Create a pool between VII-wrapped xWETH and VII-wrapped xUSDC
factory.createERC4626VaultPair(
    IERC4626(xWETH),     // First vault
    IERC4626(xUSDC),     // Second vault
    500,                 // 0.05% fee
    10,                  // Tick spacing
    sqrtPriceX96         // Initial price
);
```

### Adding Liquidity

```solidity
// 1. Deposit raw tokens lending protocol
xWETH.deposit(1000 ether, user);      // Get xWETH shares
xUSDC.deposit(2000000e6, user);       // Get xUSDC shares

// 2. Wrap into VII tokens
viiWrapperWETH.deposit(xWETHShares, user);  // Get VII-xWETH
viiWrapperUSDC.deposit(xUSDCShares, user);  // Get VII-xUSDC

// 3. Add liquidity to Uniswap V4 pool (yield automatically harvested)
positionManager.addLiquidity(poolKey, params);
```
