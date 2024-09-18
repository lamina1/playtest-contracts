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
    * @title L1 Launch Token (LL1)
    * @notice This contract manages the LL1 token with a minting and unlock schedule.
    * @dev LL1 tokens are minted all at once and have an unlock and release schedule callable by OMFMA.
*/
contract LL1 is ReentrancyGuard {
    string public constant name = "L1 Launch Token";
    string public constant symbol = "LL1";
    uint8 public constant decimals = 18;

    address public owner;
    address public omfma;
    IRules public omfmaRules;
    uint public lastHeardFromOMFMA;
    address public stakingBot;

    uint64 public periodStart = 0;
    // One period is a quarter
    uint32 public secondsPerPeriod = 7884000;
    uint32 prePeriodWindowStart = 60 * 60 * 24 * 28;
    uint32 prePeriodWindowEnd = 60 * 60 * 24 * 14;

    // Periods are measured in quarters, and a uint16 is used to represent them
    // This is safe for up to ~16384 years
    uint32[] public unlockRates;
    uint32[] public cumulativeUnlockRates;

    uint public totalDeposited; 
    uint public withdrawnTokens;
    uint public lastWithdrawn;
    uint public totalSupply;

    mapping(address => bool) public LL1Senders;
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
    event OMFMA(address indexed omfma);

    constructor(uint32 _sPP, uint32 _dS) {
        owner = msg.sender;
        if (_sPP != 0) { secondsPerPeriod = _sPP; }
        // Debug speedup
        if (_dS != 0) {
            secondsPerPeriod = secondsPerPeriod / _dS;
            prePeriodWindowStart = prePeriodWindowStart / _dS;
            prePeriodWindowEnd = prePeriodWindowEnd / _dS;
        }
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner may perform this action");
        _;
    }

    modifier onlyLL1Sender() {
        require(LL1Senders[msg.sender] == true, "Only LL1 Senders may perform this action");
        _;
    }

    modifier onlyOMFMA() {
        require(msg.sender == omfma, "Only OMFMA may perform this action");
        lastHeardFromOMFMA = block.timestamp; 
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
        * @notice Set timestamp for unlocking start
        * @param ps The timestampt for periodStart
        * @notice This function can only be called once. The timestamp has to be larger than block timestamp and up to 60 days in the future
    */
    function setPeriodStart(uint64 ps) public onlyOwner {
        require(periodStart == 0, "Period start already set");
        require(ps > block.timestamp, "Period start must be in the future");
        require(ps < block.timestamp + 60 * 24 * 3600, "Period start must be within 60 days");
        periodStart = ps;
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
            require(omfmaRules.checkLL1UnlockCall(rate, period) == true, "OMFMA Rules Violated");
        }

        if (unlockRates.length == 0 && period == 0) {
            unlockRates.push(rate);
            cumulativeUnlockRates.push(rate);
            emit UnlockRate(period, rate);
            return;
        }

        require(unlockRates.length > 0, "Run Initial Rate Setting First");
        
        ensureProperRatePeriods();

        uint64 startOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowStart;
        uint64 endOfAcceptableCallTime = period * secondsPerPeriod + periodStart - prePeriodWindowEnd;

        require(block.timestamp >= startOfAcceptableCallTime && block.timestamp <= endOfAcceptableCallTime, "Not in time window");

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
        * @notice Set an address as an LL1 sender.
        * @param dst The address to set as an LL1 sender.
    */
    function setLL1Sender(address dst) public onlyOwner {
        LL1Senders[dst] = true;
    }

    /**
        * @notice Remove an address from being an LL1 sender.
        * @param dst The address to remove as an LL1 sender.
    */
    function removeLL1Sender(address dst) public onlyOwner {
        LL1Senders[dst] = false;
    }

    /**
        * @notice Bulk transfer a fixed amount to multiple recipients.
        * @param _amt The amount to transfer to each recipient.
        * @param _recips The array of recipient addresses.
    */
    function bulkTransferQ(uint _amt, address[] calldata _recips) public onlyLL1Sender {
        require(balanceOf[msg.sender] - withdrawable(msg.sender) >= _amt * _recips.length, "Insufficient balance after withdrawal");
        require(_amt != 0, "No zero value transfers");
        
        for (uint i = 0; i < _recips.length; i++) {
            require(_recips[i] != address(0), "Can't bulk transfer to the 0 address");
            transferFrom(msg.sender, _recips[i], _amt);
        }
    }

    /**
        * @notice Bulk transfer varying amounts to multiple recipients.
        * @param _amts The array of amounts to transfer to each recipient.
        * @param _recips The array of recipient addresses.
    */
    function bulkTransfer(uint[] calldata _amts, address[] calldata _recips) public onlyLL1Sender {
        require(_amts.length == _recips.length, "Different number of recipients and amounts");
        
        uint total = 0;
        for (uint i = 0; i < _amts.length; i++) {
            require(_amts[i] != 0, "No zero value transfers");
            total += _amts[i];
        }
        require(balanceOf[msg.sender] - withdrawable(msg.sender) >= total, "Insufficient balance after withdrawal");

        for (uint i = 0; i < _amts.length; i++) {
            transferFrom(msg.sender, _recips[i], _amts[i]);
        }
    }

    /**
        * @notice Calculate the percentage of the current period completed.
        * @return The percentage of the current period completed (10k numerated).
    */
    function percentOfCurrentPeriod() public view returns (uint32) {
        if (block.timestamp < periodStart || periodStart == 0) {
            return 0;
        }
        return uint32((block.timestamp - (periodStart + secondsPerPeriod * currentPeriod())) * 100 * 10000 / secondsPerPeriod);
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
        if (LL1Senders[guy] == true) { return 0; }

        if ((totalMinted[guy] * unlockable_10k() / 10000) / 100 > totalWithdrawn[guy]) {
            return (totalMinted[guy] * unlockable_10k() / 10000 / 100 - totalWithdrawn[guy]);
        } else {
            return 0;
        }
    }

    /**
        * @notice Deposit Ether to the contract.
    */
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalMinted[msg.sender] += msg.value;

        totalDeposited += msg.value;
        totalSupply += msg.value;

        emit Deposit(msg.sender, msg.value);
    }

    /**
        * @notice Ensure rate periods are properly filled.
    */
    function ensureProperRatePeriods() public {
        uint32 priorRate = unlockRates[unlockRates.length - 1];
        uint period = currentPeriod();

        for (uint i = unlockRates.length; i < period; i++) {
            unlockRates.push(priorRate);
            cumulativeUnlockRates.push(cumulativeUnlockRates[cumulativeUnlockRates.length - 1] + priorRate);
            emit UnlockRate(uint16(unlockRates.length), priorRate);
        }
    }

    /**
        * @notice Withdraw unlocked tokens for a given address.
        * @notice Only callable by the Staking bot.
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
        require(wad > 0, "No withdrawable balance");
        require(balanceOf[guy] >= wad, "Insufficient balance");

        // Update balances
        balanceOf[guy] -= wad;
        totalWithdrawn[guy] += wad;
        totalSupply -= wad;
        withdrawnTokens += wad;
        lastWithdrawn = block.timestamp;

        // Call
        (bool _success, ) = guy.call{value: wad}("");
        require(_success, "Transfer failed");
        emit Withdrawal(guy, wad);
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
        * @param wad The amount to transfer.* @return True if the transfer succeeds.
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
        require(balanceOf[src] - withdrawable(src) >= wad, "Insufficient balance after withdrawal");
        require(msg.sender == owner || dst == owner || LL1Senders[msg.sender] == true, "Sender or recipient must be owner, or sender must be LL1 sender");

        if (src != msg.sender) {
            require(allowance[src][msg.sender] >= wad, "Insufficient allowance");
            allowance[src][msg.sender] -= wad;
        }

        if (withdrawable(src) != 0) {
            _withdraw(src);
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        uint mintAmtToMove = wad * totalMinted[src] / (totalMinted[src] - totalWithdrawn[src]);
        uint withdrawAmtToMove = (mintAmtToMove * totalWithdrawn[src]) / totalMinted[src];

        totalMinted[src] -= mintAmtToMove;
        totalMinted[dst] += mintAmtToMove;

        totalWithdrawn[src] -= withdrawAmtToMove;
        totalWithdrawn[dst] += withdrawAmtToMove;
        emit Transfer(src, dst, wad);

        return true;
    }

    /**
        * @notice Get the current period based on the current timestamp.
        * @return The current period.
    */
    function currentPeriod() public view returns (uint16) {
        if (block.timestamp < periodStart || periodStart == 0) {
            return 0;
        } else {
            return uint16((block.timestamp - periodStart) / secondsPerPeriod);
        }
    }

    /**
        * @notice Get the period for a specific timestamp.
        * @param ts The timestamp to get the period for.
        * @return The period corresponding to the timestamp.
    */
    function periodFor(uint ts) public view returns (uint16) {
        if (ts < periodStart || periodStart == 0) {
            return 0;
        } else {
            return uint16((ts - periodStart) / secondsPerPeriod);
        }
    }

    /**
        * @notice Get the number of unlock rates.
        * @return The number of unlock rates.
    */
    function rateLength() public view returns (uint16) {
        return uint16(unlockRates.length);
    }
}
