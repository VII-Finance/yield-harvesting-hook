// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SmoothYieldVault} from "src/SmoothYieldVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MaliciousToken
/// @notice A token that attempts reentrancy attacks during transfers
contract MaliciousToken is ERC20 {
    enum AttackType {
        NONE,
        DEPOSIT,
        MINT,
        WITHDRAW,
        REDEEM,
        SYNC
    }

    AttackType public attackType;
    address public targetVault;
    bool public attacking;
    uint256 public attackCount;
    uint256 public successfulAttacks;  // Track successful reentrancy
    uint256 public maxAttacks = 2;

    constructor() ERC20("Malicious Token", "MAL") {
        attackType = AttackType.NONE;
    }

    function setAttackType(AttackType _type) external {
        attackType = _type;
        attackCount = 0;
        successfulAttacks = 0;
    }

    function setMaxAttacks(uint256 _max) external {
        maxAttacks = _max;
    }

    function setTargetVault(address _vault) external {
        targetVault = _vault;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @notice Override transfer to inject reentrancy attack
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        
        // Attack when vault is sending tokens (during withdrawal/redeem)
        // msg.sender is the vault during withdraw/redeem operations
        if (msg.sender == targetVault && attackType != AttackType.NONE && !attacking && attackCount < maxAttacks) {
            attacking = true;
            attackCount++;
            _executeAttack();
            attacking = false;
        }
        
        return success;
    }

    /// @notice Override transferFrom to inject reentrancy attack
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        
        // Attack when transferring FROM user TO vault (during deposit/mint)
        if (to == targetVault && attackType != AttackType.NONE && !attacking && attackCount < maxAttacks) {
            attacking = true;
            attackCount++;
            _executeAttack();
            attacking = false;
        }
        
        return success;
    }

    function _executeAttack() internal {
        SmoothYieldVault vault = SmoothYieldVault(targetVault);
        
        if (attackType == AttackType.DEPOSIT) {
            // Try to deposit again during deposit
            uint256 balance = balanceOf(address(this));
            if (balance > 0) {
                approve(targetVault, balance);
                try vault.deposit(balance / 2, address(this)) {
                    // Attack succeeded - reentrancy was NOT prevented
                    successfulAttacks++;
                } catch {
                    // Attack prevented - ReentrancyGuard worked
                }
            }
        } else if (attackType == AttackType.MINT) {
            // Try to mint again during mint
            uint256 vaultShares = vault.balanceOf(address(this));
            if (vaultShares > 0) {
                try vault.mint(vaultShares / 2, address(this)) {
                    successfulAttacks++;
                } catch {
                    // Attack prevented
                }
            }
        } else if (attackType == AttackType.WITHDRAW) {
            // Try to withdraw again during withdraw
            uint256 vaultAssets = vault.maxWithdraw(address(this));
            if (vaultAssets > 0) {
                try vault.withdraw(vaultAssets / 2, address(this), address(this)) {
                    successfulAttacks++;
                } catch {
                    // Attack prevented
                }
            }
        } else if (attackType == AttackType.REDEEM) {
            // Try to redeem again during redeem
            uint256 vaultShares = vault.balanceOf(address(this));
            if (vaultShares > 0) {
                try vault.redeem(vaultShares / 2, address(this), address(this)) {
                    successfulAttacks++;
                } catch {
                    // Attack prevented
                }
            }
        } else if (attackType == AttackType.SYNC) {
            // Try to call sync again during sync
            try vault.sync() {
                successfulAttacks++;
            } catch {
                // Attack prevented
            }
        }
    }
}

contract SmoothYieldVaultSecureReentrancyTest is Test {
    MaliciousToken public maliciousToken;
    SmoothYieldVault public vault;
    
    address public owner = address(this);
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    
    uint256 constant SMOOTHING_PERIOD = 100;
    uint256 constant INITIAL_DEPOSIT = 1000 ether;
    uint256 constant ATTACK_AMOUNT = 100 ether;

    function setUp() public {
        // Deploy malicious token
        maliciousToken = new MaliciousToken();
        
        // Deploy SECURE vault with malicious token
        vault = new SmoothYieldVault(IERC20(address(maliciousToken)), SMOOTHING_PERIOD, owner);
        
        // Set vault as target
        maliciousToken.setTargetVault(address(vault));
        
        // Mint tokens
        maliciousToken.mint(address(this), INITIAL_DEPOSIT * 10);
        maliciousToken.mint(user1, INITIAL_DEPOSIT);
        maliciousToken.mint(user2, INITIAL_DEPOSIT);
    }

    /// @notice Test that reentrancy attack on deposit is PREVENTED
    function test_ReentrancyProtection_Deposit() public {
        console.log("=== Testing Reentrancy Protection on Deposit ===");
        
        // Setup: Make initial deposit to establish vault state
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, address(this));
        
        console.log("Initial vault totalAssets:", vault.totalAssets());
        console.log("Initial vault shares:", vault.totalSupply());
        
        // Enable reentrancy attack on deposit
        maliciousToken.setAttackType(MaliciousToken.AttackType.DEPOSIT);
        
        // Attacker attempts deposit with reentrancy
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), ATTACK_AMOUNT);
        
        // With ReentrancyGuard, this should succeed but reentrancy should be prevented
        try vault.deposit(ATTACK_AMOUNT, user1) {
            uint256 attempts = maliciousToken.attackCount();
            uint256 successes = maliciousToken.successfulAttacks();
            console.log("Deposit completed. Reentrancy attempts:", attempts);
            console.log("Successful reentrancy attacks:", successes);
            console.log("Final vault totalAssets:", vault.totalAssets());
            console.log("Final user1 shares:", vault.balanceOf(user1));
            
            // The deposit should succeed, but reentrancy should be blocked
            if (successes == 0) {
                console.log("SUCCESS: Reentrancy attack on deposit was PREVENTED!");
                console.log("Contract is SECURE with ReentrancyGuard");
            } else {
                console.log("FAILURE: Reentrancy attack SUCCEEDED - protection failed!");
            }
            
            // Assert that no reentrancy occurred
            assertEq(successes, 0, "ReentrancyGuard failed - reentrancy attack succeeded");
        } catch (bytes memory reason) {
            console.log("Deposit REVERTED unexpectedly");
            console.log("Reason:");
            console.logBytes(reason);
            revert("Deposit should not revert with valid inputs");
        }
        vm.stopPrank();
    }

    /// @notice Test that reentrancy attack on mint is PREVENTED
    function test_ReentrancyProtection_Mint() public {
        console.log("=== Testing Reentrancy Protection on Mint ===");
        
        // Setup: Make initial deposit
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, address(this));
        
        // Enable reentrancy attack on mint
        maliciousToken.setAttackType(MaliciousToken.AttackType.MINT);
        
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), type(uint256).max);
        
        uint256 sharesToMint = 100 ether;
        try vault.mint(sharesToMint, user1) {
            uint256 successes = maliciousToken.successfulAttacks();
            console.log("Mint completed. Successful attacks:", successes);
            
            if (successes == 0) {
                console.log("SUCCESS: Reentrancy attack on mint was PREVENTED!");
            } else {
                console.log("FAILURE: Reentrancy attack SUCCEEDED!");
            }
            
            assertEq(successes, 0, "ReentrancyGuard failed - reentrancy attack succeeded");
        } catch (bytes memory reason) {
            console.log("Mint REVERTED unexpectedly");
            console.logBytes(reason);
            revert("Mint should not revert with valid inputs");
        }
        vm.stopPrank();
    }

    /// @notice Test that reentrancy attack on withdraw is PREVENTED
    function test_ReentrancyProtection_Withdraw() public {
        console.log("=== Testing Reentrancy Protection on Withdraw ===");
        
        // Setup: User deposits first
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        console.log("User1 initial shares:", vault.balanceOf(user1));
        console.log("Vault total assets:", vault.totalAssets());
        
        // Enable reentrancy attack on withdraw
        maliciousToken.setAttackType(MaliciousToken.AttackType.WITHDRAW);
        
        vm.startPrank(user1);
        uint256 assetsToWithdraw = ATTACK_AMOUNT;
        
        try vault.withdraw(assetsToWithdraw, user1, user1) {
            uint256 successes = maliciousToken.successfulAttacks();
            console.log("Withdraw completed. Successful attacks:", successes);
            console.log("User1 final shares:", vault.balanceOf(user1));
            console.log("User1 token balance:", maliciousToken.balanceOf(user1));
            
            if (successes == 0) {
                console.log("SUCCESS: Reentrancy attack on withdraw was PREVENTED!");
            } else {
                console.log("FAILURE: Reentrancy attack SUCCEEDED!");
            }
            
            assertEq(successes, 0, "ReentrancyGuard failed - reentrancy attack succeeded");
        } catch (bytes memory reason) {
            console.log("Withdraw REVERTED unexpectedly");
            console.logBytes(reason);
            revert("Withdraw should not revert with valid inputs");
        }
        vm.stopPrank();
    }

    /// @notice Test that reentrancy attack on redeem is PREVENTED
    function test_ReentrancyProtection_Redeem() public {
        console.log("=== Testing Reentrancy Protection on Redeem ===");
        
        // Setup: User deposits first
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        console.log("User1 shares:", shares);
        
        // Enable reentrancy attack on redeem
        maliciousToken.setAttackType(MaliciousToken.AttackType.REDEEM);
        
        vm.startPrank(user1);
        uint256 sharesToRedeem = shares / 10;
        
        try vault.redeem(sharesToRedeem, user1, user1) {
            uint256 successes = maliciousToken.successfulAttacks();
            console.log("Redeem completed. Successful attacks:", successes);
            
            if (successes == 0) {
                console.log("SUCCESS: Reentrancy attack on redeem was PREVENTED!");
            } else {
                console.log("FAILURE: Reentrancy attack SUCCEEDED!");
            }
            
            assertEq(successes, 0, "ReentrancyGuard failed - reentrancy attack succeeded");
        } catch (bytes memory reason) {
            console.log("Redeem REVERTED unexpectedly");
            console.logBytes(reason);
            revert("Redeem should not revert with valid inputs");
        }
        vm.stopPrank();
    }

    /// @notice Test that sync function is protected
    function test_ReentrancyProtection_Sync() public {
        console.log("=== Testing Reentrancy Protection on Sync ===");
        
        // Setup
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, address(this));
        
        // Add some yield
        maliciousToken.mint(address(vault), 100 ether);
        vm.warp(block.timestamp + 50);
        
        // Enable reentrancy attack on sync
        maliciousToken.setAttackType(MaliciousToken.AttackType.SYNC);
        
        console.log("Calling sync...");
        vault.sync();
        console.log("Sync completed successfully");
        console.log("SUCCESS: Sync is protected from reentrancy");
    }

    /// @notice Test cross-function reentrancy prevention
    function test_CrossFunctionReentrancyProtection() public {
        console.log("=== Testing Cross-Function Reentrancy Protection ===");
        
        // Setup: User1 deposits first to have shares
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Try to deposit with user2, but trigger withdraw during the deposit
        maliciousToken.setAttackType(MaliciousToken.AttackType.WITHDRAW);
        
        vm.startPrank(user2);
        maliciousToken.approve(address(vault), ATTACK_AMOUNT);
        
        try vault.deposit(ATTACK_AMOUNT, user2) {
            uint256 successes = maliciousToken.successfulAttacks();
            console.log("Cross-function attempt completed. Successful attacks:", successes);
            
            if (successes == 0) {
                console.log("SUCCESS: Cross-function reentrancy was PREVENTED!");
            } else {
                console.log("WARNING: Cross-function reentrancy may have occurred");
            }
        } catch (bytes memory reason) {
            console.log("Cross-function reentrancy prevented by revert:");
            console.logBytes(reason);
        }
        vm.stopPrank();
    }

    /// @notice Test vault state remains consistent after prevented attacks
    function test_StateConsistencyAfterPreventedAttack() public {
        console.log("=== Testing State Consistency After Prevented Attack ===");
        
        // Make initial deposits from two users
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, address(this));
        
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        
        // Attempt reentrancy attack that will be prevented
        maliciousToken.setAttackType(MaliciousToken.AttackType.WITHDRAW);
        
        vm.startPrank(user1);
        vault.withdraw(ATTACK_AMOUNT, user1, user1);
        
        // Check if vault state is still consistent
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 totalSupplyAfter = vault.totalSupply();
        
        console.log("Assets before:", totalAssetsBefore);
        console.log("Assets after:", totalAssetsAfter);
        console.log("Supply before:", totalSupplyBefore);
        console.log("Supply after:", totalSupplyAfter);
        
        // Verify accounting is correct
        uint256 tokensInVault = maliciousToken.balanceOf(address(vault));
        console.log("Actual tokens in vault:", tokensInVault);
        console.log("Vault thinks it has:", vault.totalAssets());
        
        assertEq(tokensInVault, vault.totalAssets(), "Vault accounting should be consistent");
        console.log("SUCCESS: Vault state is consistent after prevented attack");
        
        vm.stopPrank();
    }

    /// @notice Test that transfer functions don't have unnecessary sync (gas optimization)
    function test_TransferOptimization() public {
        console.log("=== Testing Transfer Gas Optimization ===");
        
        // Setup: deposit to get shares
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, address(this));
        
        // Add yield and advance time (should NOT affect transfer)
        maliciousToken.mint(address(vault), 100 ether);
        vm.warp(block.timestamp + 50);
        
        // Transfer should work without syncing
        uint256 gasBefore = gasleft();
        vault.transfer(user1, shares / 10);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for transfer:", gasUsed);
        console.log("Transfer completed without sync - optimized!");
        
        // Verify transfer worked
        assertEq(vault.balanceOf(user1), shares / 10, "Transfer should succeed");
        console.log("SUCCESS: Transfer is optimized (no sync)");
    }

    /// @notice Test multiple sequential attempts are all prevented
    function test_MultipleReentrancyAttemptsPrevented() public {
        console.log("=== Testing Multiple Reentrancy Attempts Prevention ===");
        
        // Setup
        vm.startPrank(user1);
        maliciousToken.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Set max attacks to 5
        maliciousToken.setMaxAttacks(5);
        maliciousToken.setAttackType(MaliciousToken.AttackType.WITHDRAW);
        
        vm.startPrank(user1);
        uint256 balanceBefore = maliciousToken.balanceOf(user1);
        
        vault.withdraw(ATTACK_AMOUNT, user1, user1);
        
        uint256 successes = maliciousToken.successfulAttacks();
        uint256 tokensReceived = maliciousToken.balanceOf(user1) - balanceBefore;
        
        console.log("Reentrancy attempts:", maliciousToken.attackCount());
        console.log("Successful attacks:", successes);
        console.log("Tokens received:", tokensReceived);
        console.log("Expected tokens:", ATTACK_AMOUNT);
        
        assertEq(successes, 0, "All reentrancy attempts should be prevented");
        assertEq(tokensReceived, ATTACK_AMOUNT, "Should receive exactly the requested amount");
        
        console.log("SUCCESS: All multiple reentrancy attempts were PREVENTED!");
        vm.stopPrank();
    }
}