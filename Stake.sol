// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./RL1.sol";
import "./interfaces/IRL1Receiver.sol";
import "./interfaces/IERC20Mintable.sol";

/**
    * @title Staking Token
    * @notice This contract implements the Staking token with locking and RL1 claiming functionality.
    * @notice The Staking Token is an ERC20 but it's not transferrable.
    * @notice Tokens are only minted when L1 is locked, and burnt when L1 is unlocked.
*/
contract Stake is ERC20, IRL1Receiver, Ownable, ReentrancyGuard {
    struct BalanceInfo {
        uint256 balance;
        uint16 day;
    }

    event Lock(address indexed from, uint256 amount, uint16 numDays);
    event Unlock(address indexed from, uint256 amount);

    // Owner controlled parameters
    uint16 public maxDays = 3650;
    uint256 public multiplier; // 3 decimals
    IERC20Mintable public voteToken;
    address public stakingBot;

    // Periods are measure in days, and a uint16 is used to represent them
    // This is safe for up to 65535 days, or about 179 years.

    // Track Stake balances changes per address
    mapping(address => BalanceInfo[]) public stakeBalanceChanges;
    // Track RL1 deposits per day
    mapping(uint16 => uint256) public rl1Deposits;

    // Track claimed RL1 rewards per address per day
    mapping(address => mapping(uint16 => bool)) public claimed;
    // Track the largest day of claimed RL1 rewards per address
    mapping(address => uint16) public largestClaimedDay;

    // Amount of L1 staked/locked per address
    mapping(address => uint256) public locked;
    // No need to track total locked, since it is the balance of the contract

    // Track how much L1 can be unlocked per address per day
    mapping(address => mapping(uint16 => uint256)) public unlockable;
    // Track how much Staking tokens have to be burned when unlocking per address per day
    mapping(address => mapping(uint16 => uint256)) public burnable;
    // Track days that can be unlocked per address
    mapping(address => uint16[]) public unlockableDays;
    // Track total L1 that can be unlocked on a given day
    mapping(uint16 => uint256) public totalUnlockable;
    // Tack total Staking tokens that can be burned on a given day
    mapping(uint16 => uint256) public totalBurnable;
    // NOTE: unlocking amounts is always done AFTER a day is done.
    // For example, the unlockable amount for an user for day 1, is only
    // available to be unlocked when day 2 starts.

    uint public startDay;
    uint public secondsPerDay = 86400;

    RL1 public rl1;
    address public rewards;

    /**
        * @notice Constructor function.
        * @param initialOwner The initial owner of the contract.
    */
    constructor(address initialOwner, uint64 _startDay, uint32 _dS, uint256 _mult) ERC20("Staking Power", "STAKE") Ownable(initialOwner) {
        startDay = _startDay;
        multiplier = _mult;
        stakeBalanceChanges[address(this)].push(BalanceInfo(0, 0));
        rl1Deposits[0] = 0;
        if (_dS != 0) {
            secondsPerDay = secondsPerDay / _dS;
        }
    }

    modifier onlyStakingBot() {
        require(msg.sender == stakingBot, "Only Staking Bot may perform this action");
        _;
    }

    /**
        * @notice Get the stake balance changes for an address.
        * @param _addr The address to retrieve the stake balance changes for.
        * @return The array of BalanceInfo structs representing the stake balance changes.
    */
    function getStakeBalanceChanges(address _addr) public view returns (BalanceInfo[] memory) {
        return stakeBalanceChanges[_addr];
    }

    /**
        * @notice Get the total RL1 deposits for a given day
        * @param _day The day to retrieve RL1 deposits for
        * @return The amount of RL1 deposits.
    */
    function getRL1Deposits(uint16 _day) public view returns (uint256) {
        return rl1Deposits[_day];
    }

    /**
        * @notice Get the list of unlockable days for an address.
        * @param _addr The address to retrieve days for
        * @return The list of days.
    */
    function getUnlockableDays(address _addr) public view returns (uint16[] memory) {
        return unlockableDays[_addr];
    }

    /**
        * @notice Set the rewards contract address.
        * @param _rewards The address of the rewards contract.
    */
    function setRewardsContract(address _rewards) public onlyOwner {
        rewards = _rewards;
    }

    /**
        * @notice Set the RL1 contract address.
        * @param _rl1 The address of the RL1 contract.
    */
    function setRL1Contract(address _rl1) public onlyOwner {
        // Note that we allow the RL1 contract to be set multiple times, in case of upgrades or terrible problems.
        rl1 = RL1(payable(_rl1));
    }

    /**
        * @notice Set the Vote token.
        * @param _vote The address of the Vote token contract.
    */
    function setVoteToken(address _vote) public onlyOwner {
        voteToken = IERC20Mintable(_vote);
    }

    /**
        * @notice Set the maximum number of days that L1 tokens can be locked for.
        * @param _maxDays The new maximum number of days.
    */
    function setMaxDays(uint16 _maxDays) public onlyOwner {
        maxDays = _maxDays;
    }

    /**
        * @notice Set the multiplier applied to new locks of L1 (controls how many staking tokens are minted).
        * @param _multiplier The new multiplier.
    */
    function setMultiplier(uint256 _multiplier) public onlyOwner {
        multiplier = _multiplier;
    }

    /**
        * @notice Set the staking bot address.
        * @param _newBot The address of the new staking Bot.
    */
    function setStakingBot(address _newBot) public onlyOwner {
        stakingBot = _newBot;
    }

    /**
        * @notice Claim any leftover RL1 rewards from a given day where there was no stake.
        * @param _day The day to claim RL1 tokens for.
        * @param destination The address to send the RL1 tokens to.
    */
    function claimLeftovers(uint16 _day, address destination) public onlyOwner {
        require(_day < today(), "can only claim prior periods");
        require(!claimed[address(this)][_day], "already claimed");
        uint totalStake = findStakeBalanceInfoAsOf(address(this), _day);
        require (totalStake == 0, "total stake for day must be 0");
        uint claimable = rl1Deposits[_day];
        rl1.trustedTransfer(destination, claimable);
        claimed[address(this)][_day] = true;
    }

    /**
        * @notice Receive RL1 tokens.
        * @param amount The amount of RL1 tokens received.
    */
    function receiveRL1(uint256 amount) public {
        require(msg.sender == rewards, "only rewards contract can deposit");
        rl1Deposits[today()] += amount;
    }

    /**
        * @notice Claim RL1 tokens for a range of days for a given address.
        * @param _start The start day of the range.
        * @param _end The end day of the range.
        * @param _guy The address to claim RL1 tokens for.
    */
    function claimRangeFor(uint16 _start, uint16 _end, address _guy) public nonReentrant onlyStakingBot {
        for (uint16 i = _start; i <= _end; i++) {
            if (!claimed[_guy][i]) {
                _claimRL1(i, _guy);
            }
        }
    }

    /**
        * @notice Claim RL1 tokens for a given day for a given address.
        * @param _day The day to claim RL1 tokens for.
        * @param _guy The address to claim RL1 tokens for.
    */
    function claimFor(uint16 _day, address _guy) public nonReentrant onlyStakingBot {
        _claimRL1(_day, _guy);
    }

    /**
        * @notice Claim RL1 tokens for a specific day.
        * @param _day The day to claim RL1 tokens for.
    */
    function claimRL1(uint16 _day) public nonReentrant {
        _claimRL1(_day, msg.sender);
    }

    /**
        *@notice claim all function for Will.
        *
    */
    function claimAll() public nonReentrant {
        uint16 _day = today();
        for (uint16 i = 0; i < _day; i++) {
            if (!claimed[msg.sender][i]) {
                _claimRL1(i, msg.sender);
            }
        }
    }

    /**
        * @notice Claim RL1 tokens for a range of days.
        * @param _start The start day of the range.
        * @param _end The end day of the range.
    */
    function claimRL1Range(uint16 _start, uint16 _end) public nonReentrant {
        for (uint16 i = _start; i <= _end; i++) {
            if (!claimed[msg.sender][i]) {
                _claimRL1(i, msg.sender);
            }
        }
    }

    /**
        * @notice Internal function to claim RL1 tokens for a specific day and address.
        * @param _day The day to claim RL1 tokens for.
        * @param _guy The address to claim RL1 tokens for.
    */
    function _claimRL1(uint16 _day, address _guy) internal {
        require(_day < today(), "can only claim prior periods");
        require(!claimed[_guy][_day], "already claimed");

        uint claimable = claimableRL1(_guy, _day);
        if (claimable > 0) {
            rl1.trustedTransfer(_guy, claimable);
        }
        claimed[_guy][_day] = true;
        if (_day > largestClaimedDay[_guy]) {
            largestClaimedDay[_guy] = _day;
        }
    }

    /**
        * @notice Calculate the claimable RL1 tokens for an address and a specific day.
        * @param _a The address to calculate the claimable RL1 tokens for.
        * @param _day The day to calculate the claimable RL1 tokens for.
        * @return The amount of claimable RL1 tokens.
    */
    function claimableRL1(address _a, uint16 _day) public view returns (uint256) {
        uint userStake = findStakeBalanceInfoAsOf(_a, _day);
        uint totalStake = findStakeBalanceInfoAsOf(address(this), _day);
        uint contractRL1 = rl1Deposits[_day];

        if (contractRL1 == 0 || totalStake == 0) {
            return 0;
        }
        return contractRL1 * userStake / totalStake;
    }

    /**
        * @notice Calculate the claimable RL1 tokens for an address and a range of days.
        * @param _a The address to calculate the claimable RL1 tokens for.
        * @param _start The start day of the range.
        * @param _end The end day of the range.
        * @return The total amount of claimable RL1 tokens for the range.
    */
    function claimableRL1Range(address _a, uint16 _start, uint16 _end) public view returns (uint256) {
        uint total = 0;
        for (uint16 i = _start; i <= _end; i++) {
            total += claimableRL1(_a, i);
        }
        return total;
    }

    /**
        * @notice Check if Staking/Voting has started
        * @return True if start day has been reached
    */
    function hasStarted() public view returns (bool) {
        return block.timestamp >= startDay;
    }

    /**
        * @notice Get the current day.
        * @return The current day.
    */
    function today() public view returns (uint16) {
        if (block.timestamp < startDay) {
            revert("Start date not reached yet");
        }
        return uint16((block.timestamp - startDay) / secondsPerDay);
    }

    /**
        * @notice Find the stake balance info for an address as of a specific day.
        * @param _addr The address to find the stake balance info for.
        * @param _day The day to find the stake balance info for.
        * @return The BalanceInfo struct representing the stake balance info.
    */
    function findStakeBalanceInfoAsOf(address _addr, uint16 _day) public view returns (uint256) {
        if (stakeBalanceChanges[_addr].length == 0) {
            return 0;
        }
        if (stakeBalanceChanges[_addr][0].day > _day) {
            return 0;
        }

        // For most users, checking the last element of the array can save computation
        if (stakeBalanceChanges[_addr][stakeBalanceChanges[_addr].length - 1].day <= _day) {
            return stakeBalanceChanges[_addr][stakeBalanceChanges[_addr].length - 1].balance;
        }

        uint256 left = 0;
        uint256 right = stakeBalanceChanges[_addr].length;
        uint256 mid = 0;

        while (left < right) {
            mid = left + (right - left) / 2;
            if (stakeBalanceChanges[_addr][mid].day > _day) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }

        if (stakeBalanceChanges[_addr].length > left && stakeBalanceChanges[_addr][left].day == _day) {
            return stakeBalanceChanges[_addr][left].balance;
        }
        if (left > 0 && stakeBalanceChanges[_addr][left - 1].day <= _day) {
            return stakeBalanceChanges[_addr][left - 1].balance;
        }
        return 0;
    }

    /**
        * @notice Unlock locked tokens for the caller.
        * @param _day The day to unlock tokens for.
    */
    function unlock(uint16 _day) public nonReentrant {
        require(_day < today(), "can only unlock prior periods");
        uint256 value = unlockable[msg.sender][_day];
        require(value > 0, "nothing to unlock for this day");

        // Adjust L1 locked amount
        locked[msg.sender] -= value;
        totalUnlockable[_day] -= value;
        delete unlockable[msg.sender][_day];

        // Burn Stake and adjust burnable amount
        uint256 burnAmount = burnable[msg.sender][_day];
        delete burnable[msg.sender][_day];
        _burn(msg.sender, burnAmount);
        totalBurnable[_day] -= burnAmount;

        // Refund L1
        (bool _success, ) = msg.sender.call{value: value}("");
        require(_success, "Transfer failed");

        // Emit event
        emit Unlock(msg.sender, value);
    }

    /**
        * @notice Unlock locked tokens for the caller for multiple days.
        * @notice The call will revert if any of the days in the list doesn't
        * have any unlockable funds. The caller is responsible for checking
        * unlockable funds for each day before calling this function.
        * @param _days The list of days to unlock tokens for.
    */
    function unlockMultiple(uint16[] calldata _days) public {
        for (uint16 i = 0; i < _days.length; i++) {
            unlock(_days[i]);
        }
    }

    /**
        * @notice Lock tokens and mint Stake tokens.
        * @param _days The number of days to lock the tokens for.
    */
    function lock(uint16 _days) public payable {
        require(msg.value > 0, "must send l1");
        require(_days > 0, "must lock for at least 1 day");
        require(_days <= maxDays, "cannot lock for more days than allowed");

        // Get the unlock day
        uint16 unlockDay = today() + _days;
        // Compute the amount of tokens to mint
        uint256 amount = (msg.value * _days * multiplier) / 1000;
        // Mint the tokens
        _mint(msg.sender, amount);

        // Mint vote tokens if contract is set
        if (address(voteToken) != address(0)) {
            voteToken.mint(msg.sender, amount);
        }

        // Track L1 locked amount
        locked[msg.sender] += msg.value;
        // Track unlockable days
        if (unlockable[msg.sender][unlockDay] == 0) {
            unlockableDays[msg.sender].push(unlockDay);
        }
        // Track L1 unlockable amount
        unlockable[msg.sender][unlockDay] += msg.value;
        // Track Stake burnable amount
        burnable[msg.sender][unlockDay] += amount;
        // Track total L1 unlockable amount
        totalUnlockable[unlockDay] += msg.value;
        // Track total Stake burnable amount
        totalBurnable[unlockDay] += amount;

        emit Lock(msg.sender, msg.value, _days);
    }

    // Fallback + Receiver

    // If L1 is sent directly to the contract, it will be locked for 1 day.
    // This avoids accounting errors if someone sends L1 directly to the contract.

    /**
        * @notice Deposit L1 to the contract (fallback function).
    */
    fallback() external payable {
        lock(1);
    }

    /**
        * @notice Deposit L1 to the contract (receive function).
    */
    receive() external payable {
        lock(1);
    }

    // Overrides

    /**
        * @notice Internal function to update balance changes.
        * @param from The address tokens are transferred from.
        * @param to The address tokens are transferred to.
        * @param value The amount of tokens transferred.
    */
    function _update(address from, address to, uint256 value) internal override(ERC20) {
        if (to != address(0) && from != address(0)) {
            revert("transfers are not allowed");
        }

        uint16 _day = today();

        if (stakeBalanceChanges[to].length == 0 && to != address(0)) {
            stakeBalanceChanges[to].push(BalanceInfo(0, _day));
        }

        // Update receiver on mints
        if (to != address(0)) {
            BalanceInfo storage info = stakeBalanceChanges[to][stakeBalanceChanges[to].length - 1];
            if (info.day == _day) {
                info.balance += value;
                stakeBalanceChanges[to][stakeBalanceChanges[to].length - 1] = info;
            } else {
                stakeBalanceChanges[to].push(BalanceInfo(info.balance + value, _day));
            }
        }

        // Update sender on burns
        if (from != address(0)) {
            BalanceInfo storage info = stakeBalanceChanges[from][stakeBalanceChanges[from].length - 1];
            if (info.day == _day) {
                info.balance -= value;
                stakeBalanceChanges[from][stakeBalanceChanges[from].length - 1] = info;
            } else {
                stakeBalanceChanges[from].push(BalanceInfo(info.balance - value, _day));
            }
        }

        super._update(from, to, value);

        // Update total supply
        BalanceInfo storage supplyInfo = stakeBalanceChanges[address(this)][stakeBalanceChanges[address(this)].length - 1];
        if (supplyInfo.day == _day) {
            supplyInfo.balance = totalSupply();
            stakeBalanceChanges[address(this)][stakeBalanceChanges[address(this)].length - 1] = supplyInfo;
        } else {
            stakeBalanceChanges[address(this)].push(BalanceInfo(totalSupply(), _day));
        }
    }
}
