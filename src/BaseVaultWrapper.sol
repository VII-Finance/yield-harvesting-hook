// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {
    IERC20,
    Math,
    ERC4626Upgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IVaultWrapper} from "src/interfaces/IVaultWrapper.sol";

/**
 * @notice Abstract base contract for vault wrappers that provides common yield harvesting functionality
 */
abstract contract BaseVaultWrapper is ERC4626Upgradeable, IVaultWrapper {
    address public immutable yieldHarvestingHook;
    address public immutable factory;

    uint256 public constant MIN_FEE_DIVISOR = 14; // Maximum fees 7.14%

    uint256 public feeDivisor;
    address public feeReceiver;

    error NotYieldHarvester();
    error InvalidFeeDivisor();
    error NotFactory();

    constructor(address _yieldHarvestingHook) {
        yieldHarvestingHook = _yieldHarvestingHook;
        factory = msg.sender;
    }

    function _maxWithdrawableAssets() internal view virtual returns (uint256);

    function setFeeParameters(uint256 _feeDivisor, address _feeReceiver) external {
        if (msg.sender != factory) revert NotFactory();
        if (_feeDivisor != 0 && _feeDivisor < MIN_FEE_DIVISOR) revert InvalidFeeDivisor();
        feeDivisor = _feeDivisor;
        feeReceiver = _feeReceiver;
    }

    function pendingYield() public view returns (uint256, uint256) {
        uint256 totalYield = totalPendingYield();
        if (totalYield == 0) return (0, 0);

        uint256 fees = _calculateFees(totalYield);

        return (totalYield - fees, fees);
    }

    function totalPendingYield() public view returns (uint256) {
        uint256 maxWithdrawableAssets = _maxWithdrawableAssets();
        uint256 currentSupply = totalSupply();
        if (maxWithdrawableAssets > currentSupply) {
            return maxWithdrawableAssets - currentSupply;
        }
        return 0;
    }

    function _calculateFees(uint256 totalYield) internal view returns (uint256) {
        if (feeDivisor == 0 || feeReceiver == address(0)) {
            return 0;
        }
        return totalYield / feeDivisor;
    }

    function harvest(address to) external returns (uint256 harvestedAssets, uint256 fees) {
        if (msg.sender != yieldHarvestingHook) revert NotYieldHarvester();

        (harvestedAssets, fees) = pendingYield();

        if (fees > 0 && feeReceiver != address(0)) {
            _mint(feeReceiver, fees);
        }

        if (harvestedAssets > 0) {
            _mint(to, harvestedAssets);
        }
    }

    // burn capabilities so that insurance fund can burn tokens to restore solvency if there is bad debt socialization in underlying vaults
    function burn(uint256 value) public {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }
}
