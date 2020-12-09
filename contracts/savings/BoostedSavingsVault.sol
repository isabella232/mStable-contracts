pragma solidity 0.5.16;

// Internal
import { RewardsDistributionRecipient } from "../rewards/RewardsDistributionRecipient.sol";
import { BoostedTokenWrapper } from "./BoostedTokenWrapper.sol";

// Libs
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { StableMath, SafeMath } from "../shared/StableMath.sol";


contract BoostedSavingsVault is BoostedTokenWrapper, RewardsDistributionRecipient {

    using StableMath for uint256;

    IERC20 public rewardsToken;

    uint64 public constant DURATION = 7 days;
    uint64 public constant LOCKUP = 26 weeks;
    uint64 public constant UNLOCK = 2e17;

    // Timestamp for current period finish
    uint256 public periodFinish = 0;
    // RewardRate for the rest of the PERIOD
    uint256 public rewardRate = 0;
    // Last time any user took action
    uint256 public lastUpdateTime = 0;
    // Ever increasing rewardPerToken rate, based on % of total supply
    uint256 public rewardPerTokenStored = 0;
    mapping(address => UserData) public userData;
    mapping(address => uint64) public userClaim;
    mapping(address => Reward[]) public userRewards;

    struct UserData {
        uint128 rewardPerTokenPaid;
        uint128 rewards;
        uint64 lastAction;
    }

    struct Reward {
        uint64 start;
        uint64 finish;
        uint128 rate;
    }

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, address payer);
    event Withdrawn(address indexed user, uint256 amount);
    event Poked(address indexed user);
    // event RewardsLocked
    // event RewardsPaid(address indexed user, uint256 reward);

    /** @dev StakingRewards is a TokenWrapper and RewardRecipient */
    // TODO - add constants to bytecode at deployTime to reduce SLOAD cost
    constructor(
        address _nexus, // constant
        address _stakingToken, // constant
        address _stakingContract, // constant
        address _rewardsToken, // constant
        address _rewardsDistributor
    )
        public
        RewardsDistributionRecipient(_nexus, _rewardsDistributor)
        BoostedTokenWrapper(_stakingToken, _stakingContract)
    {
        rewardsToken = IERC20(_rewardsToken);
    }

    /** @dev Updates the reward for a given address, before executing function */
    modifier updateReward(address _account) {
        // Setting of global vars
        (uint256 newRewardPerToken, uint256 lastApplicableTime) = _rewardPerToken();
        // If statement protects against loss in initialisation case
        if(newRewardPerToken > 0) {
            rewardPerTokenStored = newRewardPerToken;
            lastUpdateTime = lastApplicableTime;
            // Setting of personal vars based on new globals
            if (_account != address(0)) {
                // TODO - safely typecast here
                UserData memory data = userData[_account];
                uint256 earned = _earned(_account, data.rewardPerTokenPaid, newRewardPerToken);
                if(earned > 0){
                    uint256 unlocked = earned.mulTruncate(UNLOCK);
                    uint256 locked = earned.sub(unlocked);
                    userRewards[_account].push(Reward({
                        start: uint64(data.lastAction + LOCKUP),
                        finish: uint64(now + LOCKUP),
                        rate: uint128(locked.div(now.sub(data.lastAction)))
                    }));
                    userData[_account] = UserData(uint128(newRewardPerToken), data.rewards + uint128(unlocked), uint64(now));
                } else {
                    userData[_account] = UserData(uint128(newRewardPerToken), data.rewards, uint64(now));
                }
            }
        } else if(_account == address(0)) {
            // This should only be hit once, in initialisation case
            userData[_account].lastAction = uint64(now);
        }
        _;
    }

    /** @dev Updates the reward for a given address, before executing function */
    modifier updateBoost(address _account) {
        _;
        _setBoost(_account);
    }

    /***************************************
                    ACTIONS
    ****************************************/

    /**
     * @dev Stakes a given amount of the StakingToken for the sender
     * @param _amount Units of StakingToken
     */
    function stake(uint256 _amount)
        external
        updateReward(msg.sender)
        updateBoost(msg.sender)
    {
        _stake(msg.sender, _amount);
    }

    /**
     * @dev Stakes a given amount of the StakingToken for a given beneficiary
     * @param _beneficiary Staked tokens are credited to this address
     * @param _amount      Units of StakingToken
     */
    function stake(address _beneficiary, uint256 _amount)
        external
        updateReward(_beneficiary)
        updateBoost(_beneficiary)
    {
        _stake(_beneficiary, _amount);
    }

    /**
     * @dev Withdraws stake from pool and claims any rewards
     */
    function exit()
        external
        updateReward(msg.sender)
        updateBoost(msg.sender)
    {
        _withdraw(rawBalanceOf(msg.sender));
        // _lockRewards();
    }

    /**
     * @dev Withdraws given stake amount from the pool
     * @param _amount Units of the staked token to withdraw
     */
    function withdraw(uint256 _amount)
        external
        updateReward(msg.sender)
        updateBoost(msg.sender)
    {
        _withdraw(_amount);
    }

    /**
     * @dev Uses binarysearch to find the unclaimed lockups for a given account
     */
    function _findFirstUnclaimed(uint64 _lastClaim, address _account)
        internal
        view
        returns(uint256 first)
    {
        // first = first where finish > _lastClaim
        // last = last where start < now
        uint256 len = userRewards[_account].length;
        // Binary search
        uint256 min = 0;
        uint256 max = len;
        // Will be always enough for 128-bit numbers
        for(uint256 i = 0; i < 128; i++){
            if (min >= max)
                break;
            uint256 mid = (min.add(max).add(1)).div(2);
            if (userRewards[_account][mid].finish > _lastClaim){
                min = mid;
            } else {
                max = mid.sub(1);
            }
        }
        return min;
    }

    //     function _findLastUnclaimed(uint64 _lastClaim, address _account)
    //     internal
    //     view
    //     returns(uint256 last)
    // {
    //     // last = last where start < now
    //     uint256 len = userRewards[_account].length;
    //     // Binary search
    //     uint256 min = 0;
    //     uint256 max = len;
    //     // Will be always enough for 128-bit numbers
    //     for(uint256 i = 0; i < 128; i++){
    //         if (min >= max)
    //             break;
    //         uint256 mid = (min.add(max).add(1)).div(2);
    //         if (userRewards[_account][mid].finish > _lastClaim){
    //             min = mid;
    //         } else {
    //             max = mid.sub(1);
    //         }
    //     }
    //     return min;
    // }


    function unclaimedRewards(address _account)
        external
        view
        returns (uint256 amount, uint256[] memory ids)
    {
        uint256 len = userRewards[_account].length;
        uint256 currentTime = block.timestamp;
        uint64 lastClaim = userClaim[_account];
        uint256 count = 0;

        // TODO - use binary search here to find the start and end

        for(uint256 i = 0; i < len; i++){
            Reward memory rwd = userRewards[_account][i];
            if(currentTime > rwd.start && lastClaim < rwd.finish) {
                uint256 endTime = StableMath.min(rwd.finish, currentTime);
                uint256 startTime = StableMath.max(rwd.start, lastClaim);
                uint256 unclaimed = endTime.sub(startTime).mul(rwd.rate);

                amount = amount.add(unclaimed);
                ids[count++] = i;
            }
        }
    }

    function claimRewards()
        external
        updateReward(msg.sender)
        updateBoost(msg.sender)
    {
        // transfer unlocked rewards
        // find start and end blocks
        // pass to internal fn
    }

    function claimRewards(uint256[] calldata _ids)
        external
        updateReward(msg.sender)
        updateBoost(msg.sender)
    {
        uint256 currentTime = block.timestamp;
        uint64 lastClaim = userClaim[msg.sender];
        userClaim[msg.sender] = uint64(currentTime);

        uint256 cumulative = 0;
        uint256 len = _ids.length;
        for(uint256 i = 0; i < len; i++){
            Reward memory rwd = userRewards[msg.sender][i];
            require(lastClaim <= rwd.finish, "Must be unclaimed");
            require(currentTime >= rwd.start, "Must have started");
            uint256 endTime = StableMath.min(rwd.finish, currentTime);
            uint256 startTime = StableMath.max(rwd.start, lastClaim);
            uint256 unclaimed = endTime.sub(startTime).mul(rwd.rate);
            cumulative.add(unclaimed);
        }
        rewardsToken.safeTransfer(msg.sender, cumulative);
        // emit RewardPaid(msg.sender, reward);
    }

    function pokeBoost(address _user)
        external
        updateReward(_user)
        updateBoost(_user)
    {
        emit Poked(_user);
    }

    /**
     * @dev Internally stakes an amount by depositing from sender,
     * and crediting to the specified beneficiary
     * @param _beneficiary Staked tokens are credited to this address
     * @param _amount      Units of StakingToken
     */
    function _stake(address _beneficiary, uint256 _amount)
        internal
    {
        require(_amount > 0, "Cannot stake 0");
        _stakeRaw(_beneficiary, _amount);
        emit Staked(_beneficiary, _amount, msg.sender);
    }

    function _withdraw(uint256 _amount)
        internal
    {
        require(_amount > 0, "Cannot withdraw 0");
        _withdrawRaw(_amount);
        emit Withdrawn(msg.sender, _amount);
    }


    /***************************************
                    GETTERS
    ****************************************/

    /**
     * @dev Gets the RewardsToken
     */
    function getRewardToken()
        external
        view
        returns (IERC20)
    {
        return rewardsToken;
    }

    /**
     * @dev Gets the last applicable timestamp for this reward period
     */
    function lastTimeRewardApplicable()
        public
        view
        returns (uint256)
    {
        return StableMath.min(block.timestamp, periodFinish);
    }

    /**
     * @dev Calculates the amount of unclaimed rewards per token since last update,
     * and sums with stored to give the new cumulative reward per token
     * @return 'Reward' per staked token
     */
    function rewardPerToken()
        public
        view
        returns (uint256)
    {
        (uint256 rewardPerToken_, ) = _rewardPerToken();
        return rewardPerToken_;
    }

    function _rewardPerToken()
        internal
        view
        returns (uint256 rewardPerToken_, uint256 lastTimeRewardApplicable_)
    {
        uint256 lastApplicableTime = lastTimeRewardApplicable(); // + 1 SLOAD
        uint256 timeDelta = lastApplicableTime.sub(lastUpdateTime); // + 1 SLOAD
        // If this has been called twice in the same block, shortcircuit to reduce gas
        if(timeDelta == 0) {
            return (rewardPerTokenStored, lastApplicableTime);
        }
        // new reward units to distribute = rewardRate * timeSinceLastUpdate
        uint256 rewardUnitsToDistribute = rewardRate.mul(timeDelta); // + 1 SLOAD
        uint256 supply = totalSupply(); // + 1 SLOAD
        // If there is no StakingToken liquidity, avoid div(0)
        // If there is nothing to distribute, short circuit
        if (supply == 0 || rewardUnitsToDistribute == 0) {
            return (rewardPerTokenStored, lastApplicableTime);
        }
        // new reward units per token = (rewardUnitsToDistribute * 1e18) / totalTokens
        uint256 unitsToDistributePerToken = rewardUnitsToDistribute.divPrecisely(supply);
        // return summed rate
        return (rewardPerTokenStored.add(unitsToDistributePerToken), lastApplicableTime); // + 1 SLOAD
    }

    /**
     * @dev Calculates the amount of unclaimed rewards a user has earned
     * @param _account User address
     * @return Total reward amount earned
     */
    function earned(address _account)
        public
        view
        returns (uint256)
    {
        return userData[_account].rewards + _earned(_account, userData[_account].rewardPerTokenPaid, rewardPerToken());
    }

    function _earned(address _account, uint256 _userRewardPerTokenPaid, uint256 _currentRewardPerToken)
        internal
        view
        returns (uint256)
    {
        // current rate per token - rate user previously received
        uint256 userRewardDelta = _currentRewardPerToken.sub(_userRewardPerTokenPaid); // + 1 SLOAD
        // Short circuit if there is nothing new to distribute
        if(userRewardDelta == 0){
            return 0;
        }
        // new reward = staked tokens * difference in rate
        uint256 userNewReward = balanceOf(_account).mulTruncate(userRewardDelta); // + 1 SLOAD
        // add to previous rewards
        return userNewReward;
    }


    /***************************************
                    ADMIN
    ****************************************/

    /**
     * @dev Notifies the contract that new rewards have been added.
     * Calculates an updated rewardRate based on the rewards in period.
     * @param _reward Units of RewardToken that have been added to the pool
     */
    function notifyRewardAmount(uint256 _reward)
        external
        onlyRewardsDistributor
        updateReward(address(0))
    {
        require(_reward < 1e24, "Cannot notify with more than a million units");

        uint256 currentTime = block.timestamp;
        // If previous period over, reset rewardRate
        if (currentTime >= periodFinish) {
            rewardRate = _reward.div(DURATION);
        }
        // If additional reward to existing period, calc sum
        else {
            uint256 remaining = periodFinish.sub(currentTime);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = _reward.add(leftover).div(DURATION);
        }

        lastUpdateTime = currentTime;
        periodFinish = currentTime.add(DURATION);

        emit RewardAdded(_reward);
    }
}