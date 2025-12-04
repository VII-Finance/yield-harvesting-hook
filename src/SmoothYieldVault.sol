// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title SmoothYieldVault
/// @notice ERC4626 vault that smooths yield distribution over time for yield generating rebasing tokens instead of immediate distribution
contract SmoothYieldVault is Ownable, ERC4626 {
    /// @notice Last synced asset balance
    uint256 public lastSyncedBalance;
    /// @notice Timestamp of last sync
    uint256 public lastSyncedTime;
    /// @notice Period over which yield is smoothed (in seconds)
    uint256 public smoothingPeriod;

    uint256 public remainingPeriod;

    event SmoothingPeriodUpdated(uint256 newSmoothingPeriod);
    event Sync();

    constructor(IERC20 _asset, uint256 _smoothingPeriod, address _owner) ERC4626(_asset) ERC20("", "") Ownable(_owner) {
        lastSyncedTime = block.timestamp;
        _setSmoothingPeriod(_smoothingPeriod);
    }

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string(bytes.concat("Smoothed Wrapped ", bytes(IERC20Metadata(asset()).name())));
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string(bytes.concat("SW-", bytes(IERC20Metadata(asset()).symbol())));
    }

    /// @notice Calculate unsmoothed profit since last sync
    function _profit() internal view returns (uint256) {
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        /// @dev If there is a negative yield, no profit will be reported until it is recovered by positive yield
        return currentBalance < lastSyncedBalance ? 0 : currentBalance - lastSyncedBalance;
    }

    /// @notice Calculate smoothed profit based on time elapsed
    /// @dev Profit distribution logic:
    /// - If less than a smoothing period has passed: linear distribution based on time elapsed
    /// - If one or more periods have passed without sync:
    ///   * 1 period passed: half of profit available immediately, the other half smoothed over next period
    ///   * 2 periods passed: 2/3 of profit available immediately, 1/3 smoothed over next period
    ///   * n periods passed: n/(n+1) of profit available immediately, 1/(n+1) smoothed over next period
    function _smoothedProfit() internal view returns (uint256 smoothedProfit, uint256 newRemainingPeriod) {
        uint256 timeElapsed = block.timestamp - lastSyncedTime;
        if (timeElapsed == 0) {
            return (0, remainingPeriod);
        } else {
            uint256 profit = _profit();

            // if smoothingPeriod is set to zero, make all of the profit available
            // right away
            if (smoothingPeriod == 0) {
                return (profit, 0);
            }
            // If there is no profit to be distributed when a sync happens,
            // the remainingPeriod should be set to smoothingPeriod meaning that if
            // there is any new profit after it, it needs to be smoothed over the
            // smoothingPeriod from the start
            if (profit == 0) {
                return (0, smoothingPeriod);
            }

            // this is to handle the scenario where multiple smoothing periods have passed
            // since the last sync
            if (timeElapsed > smoothingPeriod) {
                uint256 periodsPassed = (timeElapsed / smoothingPeriod) + 1;
                smoothedProfit = profit - (profit / periodsPassed);
                profit = profit - smoothedProfit;
                timeElapsed = timeElapsed % smoothingPeriod;
            }

            newRemainingPeriod =
                remainingPeriod >= timeElapsed ? remainingPeriod - timeElapsed : smoothingPeriod - timeElapsed;
            if (timeElapsed != 0) {
                smoothedProfit += (profit * timeElapsed) / (newRemainingPeriod + timeElapsed);
            }

            return (smoothedProfit, newRemainingPeriod);
        }
    }

    /// @notice Manually sync smoothed profit to lastSyncedBalance
    function sync() public {
        (uint256 smoothedProfit, uint256 newRemainingPeriod) = _smoothedProfit();
        lastSyncedBalance += smoothedProfit;
        lastSyncedTime = block.timestamp;
        remainingPeriod = newRemainingPeriod;
        emit Sync();
    }

    modifier syncBeforeAction() {
        sync();
        _;
    }

    function deposit(uint256 assets, address receiver) public override syncBeforeAction returns (uint256 shares) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override syncBeforeAction returns (uint256 assets) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        syncBeforeAction
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        syncBeforeAction
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner);
    }

    function transfer(address to, uint256 amount) public override(ERC20, IERC20) syncBeforeAction returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20, IERC20)
        syncBeforeAction
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        lastSyncedBalance += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        lastSyncedBalance -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Set smoothing period (only owner)
    /// @param _smoothingPeriod New smoothing period in seconds
    function setSmoothingPeriod(uint256 _smoothingPeriod) external onlyOwner {
        sync();
        _setSmoothingPeriod(_smoothingPeriod);
    }

    function _setSmoothingPeriod(uint256 _smoothingPeriod) internal {
        remainingPeriod = _smoothingPeriod;
        smoothingPeriod = _smoothingPeriod;
        emit SmoothingPeriodUpdated(_smoothingPeriod);
    }

    /// @notice Get total assets including smoothed profit
    function totalAssets() public view override returns (uint256) {
        (uint256 smoothedProfit,) = _smoothedProfit();
        return lastSyncedBalance + smoothedProfit;
    }
}
