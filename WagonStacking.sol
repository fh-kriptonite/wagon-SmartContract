// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

// @title: Wagon Network Token Exchanger
// @author: wagon.network
// @website: https://wagon.network
// @telegram: https://t.me/wagon_network

// ██╗    ██╗ █████╗  ██████╗  ██████╗ ███╗   ██╗
// ██║    ██║██╔══██╗██╔════╝ ██╔═══██╗████╗  ██║
// ██║ █╗ ██║███████║██║  ███╗██║   ██║██╔██╗ ██║
// ██║███╗██║██╔══██║██║   ██║██║   ██║██║╚██╗██║
// ╚███╔███╔╝██║  ██║╚██████╔╝╚██████╔╝██║ ╚████║
//  ╚══╝╚══╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Time.sol";

contract WagonStacking is Pausable, AccessControl, ReentrancyGuard {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MOVER_ROLE = keccak256("MOVER_ROLE");
    bytes32 public constant PROFIT_SHARE_ROLE = keccak256("PROFIT_SHARE_ROLE");

    // stacking period => address => amount
    mapping(uint256 => mapping(address => uint256)) public stakings;
    mapping(uint256 => mapping(address => uint256)) public withdraws;

    struct userLatestLock {
        uint256 totalLocked;
        uint256 lockedPeriod;
    }
    mapping(address => userLatestLock) public userLatestLocks;

    struct pendingWithdraw {
        uint256 amount;
        uint256 claimableTimestamp;
    }
    mapping(address => pendingWithdraw) public pendingWithdraws;

    // first lock time
    uint256 public firstLockTime;

    // stacking period => total amount
    mapping(uint256 => uint256) public totalPeriodStakes;
    mapping(uint256 => uint256) public totalProfitShares;
    mapping(uint256 => uint256) public totalPeriodWithdraws;

    mapping(uint256 => uint256) public totalPeriodLocked;

    uint public lockDate = 25;
    
    IERC20Metadata wagon;

    event UpdateLockDate(uint lockDate);
    event EmergencyMoverERC20(address erc20, address to, uint256 amount);
    event Stake(uint256 period, address staker, uint256 amount);
    event Unstake(uint256 period, address staker, uint256 amount);
    event UpdateStakingPeriod(uint256 period);
    event DistributeProfitSharing(uint256 period, uint256 amount);
    event UpdateFirstLockTime(uint timestamp);
    event RemoveAutoCompound(address staker, uint period, uint256 amount);
    event Withdraw(address staker, uint256 amount);

    // Constructor.
    // Setting all the roles needed and set wagon token.
    // @param _wagonAddress Wagon address
    constructor(address _wagonAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MOVER_ROLE, msg.sender);
        _grantRole(PROFIT_SHARE_ROLE, msg.sender);

        wagon = IERC20Metadata(_wagonAddress);
    }

    // Pause.
    // Openzeppelin pausable.
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    // Unpause.
    // Openzeppelin unpause.
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // Update Locked Date.
    // Update the lock date.
    // @param _newDate
    function updateLockedDate(uint _newDate) public onlyRole(DEFAULT_ADMIN_ROLE) {
        lockDate = _newDate;
        emit UpdateLockDate(_newDate);
    }

    // Update first lock time.
    // Update the first lock time.
    // @param _timestamp timestamp of the firt lock time
    function updateFirstLockTime(uint _timestamp) public onlyRole(DEFAULT_ADMIN_ROLE) {
        firstLockTime = _timestamp;
        emit UpdateFirstLockTime(_timestamp);
    }

    // emergencyMoveERC20.
    // Emergency move the ERC20.
    // @param _addressErc20 ERC20 address that want to be moved
    // @param _to receiver address
    // @param _amount amount to be send
    function emergencyMoveErc20(address _addressErc20, address _to, uint256 _amount) external onlyRole(MOVER_ROLE) nonReentrant {
        IERC20 erc20 = IERC20(_addressErc20);
        erc20.transfer(_to, _amount);
        emit EmergencyMoverERC20(_addressErc20, _to, _amount);
    }
    
    // updateUserLatestLock.
    // Update user latest locked status which are:
    // - total wagon locked
    // - locked period
    function updateUserLatestLock() private {
        uint256 lockedPeriod = getCurrentLockedPeriod();
        if(lockedPeriod == 0) return;
        if(lockedPeriod == userLatestLocks[msg.sender].lockedPeriod) return;

        userLatestLocks[msg.sender].totalLocked = getCurrentTotalUserLocked();
        userLatestLocks[msg.sender].lockedPeriod = lockedPeriod;
    }

    // updateTotalLatestLocked.
    // Update total latest locked
    function updateTotalLatestLocked() private {
        uint256 lockedPeriod = getCurrentLockedPeriod();
        if(lockedPeriod == 0) return;
        if(totalPeriodLocked[lockedPeriod] > 0) return;

        totalPeriodLocked[lockedPeriod] = getTotalStaked(lockedPeriod);
    }

    // getCurrentPeriod.
    // Get the staking period time to be locked
    function getCurrentPeriod() public view returns (uint256) {
        if(firstLockTime == 0) return 1;

        uint256 timeNow = block.timestamp;
        if(timeNow <= firstLockTime) return 1;

        //  return different month between now and the first lock timestamp
        uint256 diffMonths = BokkyPooBahsDateTimeLibrary.diffMonths(firstLockTime, block.timestamp);
        return diffMonths + 2;
    }

    // getCurrentLockedPeriod.
    // Get the locked period
    function getCurrentLockedPeriod() public view returns(uint256) {
        return getCurrentPeriod() - 1;
    }

    // getCurrentTotalUserLocked.
    // Get total user current locked WAG.
    function getCurrentTotalUserLocked() public view returns(uint256) {
        uint256 lockedPeriod = getCurrentLockedPeriod();
        uint256 totalUserStaked = getTotalUserPeriodLocked(lockedPeriod);

        return totalUserStaked;
    }

    // getTotalUserPeriodLocked.
    // Get total user locked WAG at a certain locked period
    // @param _lockedPeriod locked period
    function getTotalUserPeriodLocked(uint256 _lockedPeriod) public view returns(uint256) {
        if(_lockedPeriod == 0) return 0;
        if(_lockedPeriod == 1) return stakings[1][msg.sender];

        userLatestLock memory userLock = userLatestLocks[msg.sender];
        uint256 totalUserStaked = userLock.totalLocked;
        uint256 latestLockedPeriod = userLock.lockedPeriod;

        if(latestLockedPeriod > 0 && latestLockedPeriod <= _lockedPeriod) {
            totalUserStaked += calculateReward(latestLockedPeriod, totalUserStaked);
            totalUserStaked -= withdraws[latestLockedPeriod][msg.sender];
        }

        uint256 i = latestLockedPeriod + 1;
        for(i; i <= _lockedPeriod; i++) {
            totalUserStaked += stakings[i][msg.sender];
            if (i == _lockedPeriod) continue;
            totalUserStaked += calculateReward(i, totalUserStaked);
            totalUserStaked -= withdraws[i][msg.sender];
        }

        return totalUserStaked;
    }

    // calculateReward.
    // Calculate reward with by specified user staked at a certain period
    // @param _period period to calculate the reward
    // @param _totalUserStaked total of user staked for the reward
    function calculateReward(uint256 _period, uint256 _totalUserStaked) internal view returns(uint256) {
        uint256 totalStaked = getTotalStaked(_period);
        return _totalUserStaked * totalProfitShares[_period] / totalStaked;
    }

    // getTotalStaked.
    // Get total staked in certain period
    // @param _period period to calculate the reward
    function getTotalStaked(uint256 _period) public view returns(uint256) {
        if(_period == 0) return 0;
        if(_period == 1) return totalPeriodStakes[1];

        if(totalPeriodLocked[_period] > 0) return totalPeriodLocked[_period];

        uint256 totalStaked = 0;

        uint256 previousLockedPeriod = totalPeriodLocked[_period-1];
        if(previousLockedPeriod > 0) {
            totalStaked = previousLockedPeriod;
            totalStaked += totalProfitShares[_period-1];
            totalStaked -= totalPeriodWithdraws[_period-1];
            totalStaked += totalPeriodStakes[_period];
            return totalStaked;
        }
        
        uint i = 1;
        for(i; i <= _period; i++) {
            totalStaked += totalPeriodStakes[i];
            if (i == _period) continue;
            totalStaked += totalProfitShares[i];
            totalStaked -= totalPeriodWithdraws[i];
        }
        return totalStaked;
    }

    // getUserReward.
    // Get user reward from current locked period.
    function getUserReward() public view returns(uint256) {
        uint256 period = getCurrentLockedPeriod();
        uint256 userReward = getUserPeriodReward(period);
        
        return userReward;
    }

    // getUserPeriodReward.
    // Get user reward from certain locked period.
    // @param _period period to get the reward
    function getUserPeriodReward(uint256 _period) public view returns(uint256) {
        if(_period == 0) return 0;

        uint256 totalUserLocked = getTotalUserPeriodLocked(_period);
        uint256 totalStaked = getTotalStaked(_period);
        return totalUserLocked * totalProfitShares[_period] / totalStaked;
    }

    // stakeWagon.
    // Stake WAG to be lock.
    // @param _amountWagon Amount of wagon to be stake
    function stakeWagon(uint256 _amountWagon) public whenNotPaused nonReentrant{
        require(wagon.balanceOf(msg.sender) >= _amountWagon, "Balance not enough.");
        wagon.transferFrom(msg.sender, address(this), _amountWagon);
        
        uint256 period = getCurrentPeriod();

        stakings[period][msg.sender] += _amountWagon;
        totalPeriodStakes[period] += _amountWagon;
        updateUserLatestLock();
        updateTotalLatestLocked();
        emit Stake(period, msg.sender, _amountWagon);
    }

    // unstakeWagon.
    // Unstake WAG before it locked.
    // @param _amountWagon Amount of wagon to be stake
    function unstakeWagon(uint256 _amountWagon) public whenNotPaused nonReentrant{
        uint256 period = getCurrentPeriod();

        uint256 staked = stakings[period][msg.sender];
        require(staked >= _amountWagon, "Too much amount to unstake.");

        stakings[period][msg.sender] -= _amountWagon;
        totalPeriodStakes[period] -= _amountWagon;
        wagon.transfer(msg.sender, _amountWagon);

        updateUserLatestLock();
        updateTotalLatestLocked();
        emit Unstake(period, msg.sender, _amountWagon);
    }

    // distributeProfitSharing.
    // Add Wagon to be distribute for rewards on current locked period.
    // @param _amountWagon Amount of wagon to be stake
    function distributeProfitSharing(uint256 _amountWagon) public onlyRole(PROFIT_SHARE_ROLE){
        uint256 lockedPeriod = getCurrentLockedPeriod();
        require(lockedPeriod > 0, "Staking period not yet started");

        require(wagon.balanceOf(msg.sender) >= _amountWagon, "Balance not enough.");
        wagon.transferFrom(msg.sender, address(this), _amountWagon);
        
        totalProfitShares[lockedPeriod] += _amountWagon;
        updateTotalLatestLocked();
        emit DistributeProfitSharing(lockedPeriod, _amountWagon);
    }

    // getTotalUserWithdrawable.
    // Get how many wagon user can uncompound from this locked period.
    function getTotalUserWithdrawable() public view returns(uint256 totalWithdrawable) {
        uint256 lockedPeriod = getCurrentLockedPeriod();
        if(lockedPeriod == 0) return 0;

        totalWithdrawable = getCurrentTotalUserLocked();
        totalWithdrawable += calculateReward(lockedPeriod, totalWithdrawable);
        totalWithdrawable -= withdraws[lockedPeriod][msg.sender];
        
        return totalWithdrawable;
    }
    
    // removeAutoCompound.
    // Remove user's locked WAG and reward from auto compound.
    // @params _amount Amount of wagon to be uncompound
    function removeAutoCompound(uint256 _amount) public nonReentrant{
        require(_amount > 0, "Cannot withdraw 0");
        
        uint256 totalUserWithdrawable = getTotalUserWithdrawable();
        require(_amount <= totalUserWithdrawable, "Not enough locked withdrawable");

        uint256 lockedPeriod = getCurrentLockedPeriod();
        withdraws[lockedPeriod][msg.sender] += _amount;
        totalPeriodWithdraws[lockedPeriod] += _amount;

        pendingWithdraws[msg.sender].amount += _amount;
        pendingWithdraws[msg.sender].claimableTimestamp = getLockTimePeriod(lockedPeriod + 1);

        updateUserLatestLock();
        updateTotalLatestLocked();
        emit RemoveAutoCompound(msg.sender, lockedPeriod, _amount);
    }

    // getLockTimePeriod.
    // Get timestamp when a period will be locked
    // @params period
    function getLockTimePeriod(uint256 period) public view returns (uint256) {
        if(firstLockTime == 0) return 0;
        if(period < 1) return 0;

        return BokkyPooBahsDateTimeLibrary.addMonths(firstLockTime , period - 1);
    }

    // withdraw.
    // Withdraw user's uncompounded WAG
    // @params _amount amount of WAG to be withdraw
    function withdraw(uint256 _amount) public nonReentrant {
        require(_amount > 0, "Cannot withdraw 0");
        
        pendingWithdraw memory userPendingWithdrawable = pendingWithdraws[msg.sender];
        require(_amount <= userPendingWithdrawable.amount, "Not enough pending withdrawable");

        require(block.timestamp >= userPendingWithdrawable.claimableTimestamp, "Not yet time to withdraw");
        
        if (userPendingWithdrawable.amount - _amount == 0)
            pendingWithdraws[msg.sender].claimableTimestamp = 0;

        pendingWithdraws[msg.sender].amount -= _amount;

        wagon.transfer(msg.sender, _amount);
        updateUserLatestLock();
        updateTotalLatestLocked();
        emit Withdraw(msg.sender, _amount);
    }

}