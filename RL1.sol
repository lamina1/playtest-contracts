// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
    * @title OMFMA Rules Interface
    * @notice This is the interface to the OMFMA rules contract.
*/
interface IRules {
    function checkRL1UnlockCall(uint32 rate, uint16 period) external view returns (bool);
    function checkRL1MiningCall(uint32 rate, uint16 period) external view returns (bool);
    function checkLL1UnlockCall(uint32 rate, uint16 period) external view returns (bool);
}

/**
    * @title L1 Mining Rewards Token (RL1)
    * @notice This contract manages the RL1 token with minting, unlock schedule, and release schedule.
    * @dev RL1 tokens are minted all at once and have an unlock and release schedule callable by OMFMA.
*/
contract RL1 is ReentrancyGuard {
    string public constant name = "L1 Mining Rewards Token";
    string public constant symbol = "RL1";
    uint8 public constant decimals = 18;

    address public owner;
    address public omfma;
    IRules public omfmaRules;
    uint public lastHeardFromOMFMA;
    address public rewardsContract;
    address public stakingBot;

    uint64 public periodStart;
    // One period is a quarter
    uint32 public secondsPerPeriod = 7884000;
    uint32 prePeriodWindowStart = 60 * 60 * 24 * 28;
    uint32 prePeriodWindowEnd = 60 * 60 * 24 * 14;

    // Periods are measured in quarters, and a uint16 is used to represent them
    // This is safe for up to ~16384 years
    uint32[] public unlockRates;
    uint32[] public cumulativeUnlockRates;

    uint32[] public claimableReleaseRate;
    uint[] public claimableProofTokens;
    uint[] public cumClaimableProofTokens;
    uint public totalDeposited;
    uint public claimedTokens;
    uint public lastClaimed;

    mapping(address => bool) public RL1Senders;
    mapping(address => uint) public balanceOf;
    mapping(address => uint) public totalMinted;
    mapping(address => uint) public totalWithdrawn;
    mapping(address => mapping(address => uint)) public allowance;

    address pendingOwner = address(0);

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);
    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);
    event UnlockRate(uint16 period, uint32 rate);
    event Claimable(uint16 period, uint numTokens);
    event ClaimableRate(uint16 period, uint32 rate);
    event Claim(uint64 time, uint numTokens);
    event OMFMA(address indexed omfma);
    event Mint(uint wad);

    constructor(address rewards, uint64 _pS, uint32 _sPP, uint32 _dS) {
        owner = msg.sender;
        if (_pS != 0) { periodStart = _pS; }
        if (_sPP != 0) { secondsPerPeriod = _sPP; }
        if (_dS != 0) {
            secondsPerPeriod = secondsPerPeriod / _dS;
            prePeriodWindowStart = prePeriodWindowStart / _dS;
            prePeriodWindowEnd = prePeriodWindowEnd / _dS;
        }

        rewardsContract = rewards;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner may perform this action");
        _;
    }

    modifier onlyRL1Sender() {
        require(RL1Senders[msg.sender] == true, "Only RL1 Senders may perform this action");
        _;
    }

    modifier onlyOMFMA() {
        require(msg.sender == omfma, "Only OMFMA may perform this action");
        lastHeardFromOMFMA = block.timestamp;
        _;
    }

    modifier onlyRewards() {
        require(msg.sender == rewardsContract, "Only Rewards Contract may call this function");
        _;
    }

    modifier onlyStakingBot() {
        require(msg.sender == stakingBot, "Only Staking Bot may perform this action");
        _;
    }

    /**
        * @notice Set the OMFMA address.
        * @param _omfma The new OMFMA address.
    */
    function setOMFMA(address _omfma) public {
        require(_omfma != address(0), "OMFMA cannot be the 0 address");
        if (omfma == address(0) && msg.sender == owner) {
            omfma = _omfma;
        } else if (msg.sender == omfma) {
            omfma = _omfma;
        } else if (lastHeardFromOMFMA + secondsPerPeriod * 12 / 10 < block.timestamp && msg.sender == owner) {
            omfma = _omfma;
        } else {
            revert("Conditions not met to set OMFMA address");
        }

        emit OMFMA(omfma);
    }

    /**
        * @notice Set the OMFMA Rules address.
        * @param _omfmarules The new OMFMA Rules address.
    */
    function setOMFMARules(address _omfmarules) public onlyOwner {
        omfmaRules = IRules(_omfmarules);
    }

    /**
        * @notice Set the rewards contract address.
        * @param dst The new rewards contract address.
    */
    function setRewardsContract(address dst) public onlyOwner {
        rewardsContract = dst;
    }

    /**
        * @notice Transfer ownership to a new owner.
        * @param newOwner The address of the new owner.
    */
    function transferOwnership(address newOwner) public onlyOwner {
        pendingOwner = newOwner;
    }

    /**
        * @notice Set the staking bot address.
        * @param _newBot The address of the new staking Bot.
    */
    function setStakingBot(address _newBot) public onlyOwner {
        stakingBot = _newBot;
    }

    /**
        * @notice Accept ownership transfer.
    */
    function acceptOwnership() public {
        require(msg.sender == pendingOwner, "Only pending owner may perform this action");
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /**
        * @notice Set the unlock rate for a specific period.
        * @param rate The unlock rate (10k numerated).
        * @param period The period to set the unlock rate for.
    */
    function setUnlockRate(uint32 rate, uint16 period) public onlyOMFMA {
        require(rate <= 100 * 10000, "Unlock rate too high");
        if (address(omfmaRules) != address(0)) { // If we have rules, check them
            require(omfmaRules.checkRL1UnlockCall(rate, period) == true, "OMFMA Rules Violated");
        }

        if (unlockRates.length == 0 && period == 0) {
            unlockRates.push(rate);
            cumulativeUnlockRates.push(rate);
            emit UnlockRate(period, rate);
            return;
        }

        require(unlockRates.length > 0, "Run Initial Rate Setting First");

        uint64 startOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowStart;
        uint64 endOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowEnd;
        require(block.timestamp >= startOfAcceptableCallTime && block.timestamp <= endOfAcceptableCallTime, "Not in time window");

        uint32 priorRate = unlockRates[unlockRates.length - 1];

        for (uint i = unlockRates.length; i < period; i++) {
            unlockRates.push(priorRate);
            cumulativeUnlockRates.push(cumulativeUnlockRates[cumulativeUnlockRates.length - 1] + priorRate);
            emit UnlockRate(uint16(unlockRates.length), priorRate);
        }

        // Replace rate if already set for this period
        if (period == unlockRates.length - 1) {
            unlockRates[period] = rate;
            cumulativeUnlockRates[period] = cumulativeUnlockRates[period-1] + rate;
        } else {
            // Push new rate
            unlockRates.push(rate);
            cumulativeUnlockRates.push(cumulativeUnlockRates[cumulativeUnlockRates.length-1] + rate);
        }
        emit UnlockRate(period, rate);
    }

    /**
        * @notice Set the mining rate for a specific period.
        * @param rate The mining rate (10k numerated). - e.g. 5000 = 0.5%
        * @param period The period to set the mining rate for.
    */
    function setMiningRate(uint32 rate, uint16 period) public onlyOMFMA {
        require(rate <= 25 * 10000, "Mining rate too high"); 
        if (address(omfmaRules) != address(0)) { // If we have rules, check them
            require(omfmaRules.checkRL1MiningCall(rate, period) == true, "OMFMA Rules Violated");
        }

        if (claimableReleaseRate.length == 0 && period == 0) {
            claimableReleaseRate.push(rate);
            claimableProofTokens.push(rate * balanceOf[address(this)] / 10000 / 100);
            cumClaimableProofTokens.push(rate * balanceOf[address(this)] / 10000 / 100);
            emit ClaimableRate(period, rate);
            emit Claimable(period, claimableProofTokens[0]);
            return;
        }

        require(claimableReleaseRate.length > 0, "Run Initial Rate Setting First"); 

        uint64 startOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowStart;
        uint64 endOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowEnd;
        require(block.timestamp >= startOfAcceptableCallTime && block.timestamp <= endOfAcceptableCallTime, "Not in time window");

        ensureProperRewardPeriods();

        uint available = totalDeposited - cumClaimableProofTokens[period - 1];
        // Replace rate if already set for this period
        if (period == claimableReleaseRate.length - 1) {
            claimableReleaseRate[period] = rate;
            claimableProofTokens[period] = available * claimableReleaseRate[period] / 10000 / 100;
            cumClaimableProofTokens[period] = claimableProofTokens[period] + cumClaimableProofTokens[period - 1];
        } else {
            // Push new rate
            claimableReleaseRate.push(rate);
            claimableProofTokens.push(available * claimableReleaseRate[period] / 10000 / 100);
            cumClaimableProofTokens.push(claimableProofTokens[period] + cumClaimableProofTokens[period - 1]);
        }
        emit ClaimableRate(period, rate);
        emit Claimable(period, claimableProofTokens[period]);
    }

    /**
        * @notice Internal function to transfer tokens from a source address to a recipient.
        * @param src The source address.
        * @param dst The recipient address.
        * @param wad The amount to transfer.
    */
    function _transferFrom(address src, address dst, uint wad) internal nonReentrant {
        require(balanceOf[src] >= wad, "Insufficient Balance");

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        totalMinted[src] -= wad;
        totalMinted[dst] += wad;

        emit Transfer(src, dst, wad);
    }

    /**
        * @notice Transfer tokens from the rewards contract to a recipient.
        * @param dst The recipient address.
        * @param wad The amount to transfer.
    */
    function rewardsTransfer(address dst, uint wad) public onlyRewards {
        require(balanceOf[rewardsContract] >= wad, "Insufficient Balance.. Uh Oh.");

        balanceOf[rewardsContract] -= wad;
        balanceOf[dst] += wad;

        totalMinted[rewardsContract] -= wad;
        totalMinted[dst] += wad;

        emit Transfer(rewardsContract, dst, wad);
    }

    /**
        * @notice Transfer tokens from an RL1 sender to a recipient.
        * @param dst The recipient address.
        * @param wad The amount to transfer.
    */
    function trustedTransfer(address dst, uint wad) public onlyRL1Sender nonReentrant {
        require(balanceOf[msg.sender] >= wad, "Insufficient Balance.. Uh Oh.");

        balanceOf[msg.sender] -= wad;
        balanceOf[dst] += wad;

        totalMinted[msg.sender] -= wad;
        totalMinted[dst] += wad;

        emit Transfer(msg.sender, dst, wad);
    }

    /**
        * @notice Set an address as an RL1 sender.
        * @param dst The address to set as an RL1 sender.
    */
    function setRL1Sender(address dst) public onlyOwner {
        RL1Senders[dst] = true;
    }

    /**
        * @notice Remove an address from being an RL1 sender.
        * @param dst The address to remove as an RL1 sender.
    */
    function removeRL1Sender(address dst) public onlyOwner {
        RL1Senders[dst] = false;
    }

    /**
        * @notice Claimable helper function.
    */
   function claimable() public view returns (uint) { // can't ensure Proper rewards because this is a view function
        uint16 startPeriod = periodFor(lastClaimed);
        uint16 endPeriod = currentPeriod();

        uint _claimable = 0;
        for (uint i = startPeriod; i <= endPeriod; i++) {
            _claimable += percentOfPeriod(uint16(i), lastClaimed, block.timestamp) * claimableProofTokens[i] / 100 / 10000;
        }
        return _claimable;
   } 

    /**
        * @notice Claim tokens owed to the Rewards Contract.
    */
    function claim() public {
        require(claimableProofTokens.length > 0, "Finish setting up claimable tokens");

        ensureProperRewardPeriods();

        uint _claimable = claimable();
        require(_claimable > 0, "No claimable balance");
        _transferFrom(address(this), rewardsContract, _claimable);

        lastClaimed = block.timestamp;
        claimedTokens += _claimable;
    }

    /**
        * @notice Get the period for a specific timestamp.
        * @param ts The timestamp to get the period for.
        * @return The period corresponding to the timestamp.
    */
    function periodFor(uint ts) public view returns (uint16) {
        if (ts < periodStart) {
            return 0;
        }
        return uint16((ts - periodStart) / secondsPerPeriod);
    }

    /**
        * @notice Calculate the percentage of a period between two timestamps.
        * @param period The period to calculate the percentage for.
        * @param start The start timestamp.
        * @param end The end timestamp.
        * @return The percentage of the period (10k numerated).
    */
    function percentOfPeriod(uint16 period, uint start, uint end) public view returns (uint32) {
        require(end > start, "don't play please");
        if (start > periodEndSeconds(period)) { return 0; }
        if (end < periodStartSeconds(period)) { return 0; }
        if (start <= periodStartSeconds(period) && end >= periodEndSeconds(period)) { return 100 * 10000; }

        if (start <= periodStartSeconds(period)) {
            start = periodStartSeconds(period);
        }
        if (end >= periodEndSeconds(period)) {
            end = periodEndSeconds(period);
        }

        return uint32((end - start + 1) * 100 * 10000 / secondsPerPeriod);
    }

    /**
        * @notice Calculate the percentage of the current period completed.
        * @return The percentage of the current period completed (10k numerated).
    */
    function percentOfCurrentPeriod() public view returns (uint32) {
        if (block.timestamp < periodStart) {
            return 0;
        }
        return uint32((block.timestamp - (periodStart + secondsPerPeriod * currentPeriod())) * 100 * 10000 / secondsPerPeriod);
    }

    /**
        * @notice Get the start timestamp of a specific period.
        * @param period The period to get the start timestamp for.
        * @return The start timestamp of the period.
    */
    function periodStartSeconds(uint16 period) public view returns (uint) {
        return periodStart + secondsPerPeriod * period;
    }

    /**
        * @notice Get the end timestamp of a specific period.
        * @param period The period to get the end timestamp for.
        * @return The end timestamp of the period.
    */
    function periodEndSeconds(uint16 period) public view returns (uint) {
        return periodStartSeconds(period) + secondsPerPeriod;
    }

    /**
        * @notice Calculate the unlockable amount (10k numerated).
        * @return The unlockable amount (10k numerated).
    */
    function unlockable_10k() public view returns (uint32) {
        uint filledPeriods = unlockRates.length;
        if (filledPeriods == 0) {
            return 0;
        }

        uint filledAsOfLastPeriod = 0;
        uint filledFromCurrentPeriod = 0;

        if (filledPeriods >= currentPeriod() + 1) {
            if (currentPeriod() > cumulativeUnlockRates.length) {
                filledAsOfLastPeriod = cumulativeUnlockRates[currentPeriod() - 1];
            }
            filledFromCurrentPeriod = uint(unlockRates[currentPeriod()]) * percentOfCurrentPeriod() / 10000 / 100;
        } else {
            uint fillRate = unlockRates[filledPeriods - 1];
            uint catchupPeriods = currentPeriod() - cumulativeUnlockRates.length;

            filledAsOfLastPeriod = cumulativeUnlockRates[cumulativeUnlockRates.length - 1] + fillRate * catchupPeriods;
            filledFromCurrentPeriod = fillRate * percentOfCurrentPeriod() / 10000 / 100;
        }

        uint total = filledAsOfLastPeriod + filledFromCurrentPeriod;
        if (total > 100 * 10000) {
            return uint32(100 * 10000);
        }
        return uint32(total);
    }

    /**
        * @notice Calculate the withdrawable amount for an address.
        * @param guy The address to calculate the withdrawable amount for.
        * @return The withdrawable amount.
    */
    function withdrawable(address guy) public view returns (uint) {
        if (RL1Senders[guy] == true) { return 0; }

        if ((totalMinted[guy] * unlockable_10k() / 10000) / 100 > totalWithdrawn[guy]) {
            return (totalMinted[guy] * unlockable_10k() / 10000 / 100 - totalWithdrawn[guy]);
        } else {
            return 0;
        }
    }

    /**
        * @notice Mint a certain amount of RL1.
        * @param wad The amount of RL1 to mint.
    */
    function mintRL1(uint wad) public onlyOwner {
        require (totalMinted[address(this)] + wad <= 500_000_000 ether, "Already minted 500M RL1");

        balanceOf[address(this)] += wad;
        totalMinted[address(this)] += wad;

        totalDeposited += wad;

        ensureProperRewardPeriods();
        uint index = currentPeriod();

        claimableProofTokens[index] += wad * claimableReleaseRate[index] / 10000 / 100; 
        cumClaimableProofTokens[index] += wad * claimableReleaseRate[index] / 10000 / 100;

        emit Mint(wad);
    }

    /**
        * @notice Deposit L1 to the contract.
    */
    function deposit() public payable { 
        emit Deposit(address(this), msg.value);
    }

    /**
        * @notice Ensure rate periods are properly filled.
    */
    function ensureProperRatePeriods() public {}

    /**
        * @notice Ensure the release rate is properly filled.
    */
    function ensureProperReleaseRate() public {
        if (claimableReleaseRate.length > currentPeriod()) { return; }

        for (uint i = claimableReleaseRate.length; i <= currentPeriod(); i++) {
            claimableReleaseRate.push(claimableReleaseRate[i - 1]);
        }
    }

    /**
        * @notice Ensure reward periods are properly filled.
    */
    function ensureProperRewardPeriods() public {
        if (claimableProofTokens.length > currentPeriod()) { return; }

        ensureProperReleaseRate();

        for (uint i = claimableProofTokens.length; i <= currentPeriod(); i++) {
            uint available = totalDeposited - cumClaimableProofTokens[i - 1];
            claimableProofTokens.push(available * claimableReleaseRate[i] / 10000 / 100);
            cumClaimableProofTokens.push(claimableProofTokens[i] + cumClaimableProofTokens[i - 1]);

            emit ClaimableRate(uint16(i), claimableReleaseRate[i]);
            emit Claimable(uint16(i), claimableProofTokens[i]);
        }
    }

    /**
        * @notice Withdraw unlocked tokens for a given address.
        * @notice Only callable by an RL1 sender.
        * @param guy The address to withdraw tokens for.
    */
    function withdrawFor(address guy) public nonReentrant onlyStakingBot {
        _withdraw(guy);
    }

    /**
        * @notice Withdraw unlocked tokens.
    */
    function withdraw() public nonReentrant {
        _withdraw(msg.sender);
    }

    /**
        * @notice Internal function to withdraw tokens for an address.
        * @param guy The address to withdraw tokens for.
    */
    function _withdraw(address guy) internal {
        uint wad = withdrawable(guy);
        require(wad > 0, "No Withdrawable Balance");
        require(balanceOf[guy] >= wad, "Insufficient balance");

        // Update balances
        balanceOf[guy] -= wad;
        totalWithdrawn[guy] += wad;
        totalWithdrawn[address(this)] += wad;

        // Call
        (bool _success, ) = guy.call{value: wad}("");
        require(_success, "Transfer failed");
        emit Withdrawal(guy, wad);
    }

    /**
        * @notice Get the total supply of tokens.
        * @return The total supply.
    */
    function totalSupply() public view returns (uint) {
        //return address(this).balance;
        return totalDeposited - totalWithdrawn[address(this)];
    }

    /**
        * @notice Approve an address to spend tokens on behalf of the sender.
        * @param guy The address to approve.
        * @param wad The amount to approve.
        * @return True if the approval succeeds.
    */
    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    /**
        * @notice Transfer tokens from the sender to a recipient.
        * @param dst The address of the recipient.
        * @param wad The amount to transfer.
        * @return True if the transfer succeeds.
    */
    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /**
        * @notice Transfer tokens from a source address to a recipient.
        * @param src The source address.
        * @param dst The recipient address.
        * @param wad The amount to transfer.
        * @return True if the transfer succeeds.
    */
    function transferFrom(address src, address dst, uint wad) public nonReentrant returns (bool) {
        require(balanceOf[src] - withdrawable(src) >= wad, "We're going to withdraw some L1 soon and you won't have enough after.");
        require(msg.sender == owner || dst == owner, "Sender or Recipient must be owner");

        if (src != msg.sender) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        if (withdrawable(src) != 0) {
            _withdraw(src);
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        uint mintAmtToMove = wad * totalMinted[src] / (totalMinted[src] - totalWithdrawn[src]);
        uint claimAmtToMove = (mintAmtToMove * totalWithdrawn[src]) / totalMinted[src];

        totalMinted[src] -= mintAmtToMove;
        totalMinted[dst] += mintAmtToMove;

        totalWithdrawn[src] -= claimAmtToMove;
        totalWithdrawn[dst] += claimAmtToMove;

        emit Transfer(src, dst, wad);
        return true;
    }

    /**
        * @notice Get the number of unlock rates.
        * @return The number of unlock rates.
    */
    function rateLength() public view returns (uint16) {
        return uint16(unlockRates.length);
    }

    /**
        * @notice Get the number of claimable proof tokens.
        * @return The number of claimable proof tokens.
    */
    function proofTokensLength() public view returns (uint16) {
        return uint16(claimableProofTokens.length);
    }

    /**
        * @notice Get the current period based on the current timestamp.
        * @return The current period.
    */
    function currentPeriod() public view returns (uint16) {
        if (block.timestamp < periodStart) {
            return 0;
        } else {
            return uint16((block.timestamp - periodStart) / secondsPerPeriod);
        }
    }
}
