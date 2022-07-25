// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract UNASPresale is ReentrancyGuard, Context, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    struct refInfo {
        uint256 unclaimed;
        uint256 withdrawn;
        address[] users;
    }

    struct purchaseInfo {
        address purchaser;
        address valueToken;
        uint256 value;
        uint256 amount;
        uint256 round;
        address referral;
    }

    // The token being sold
    IERC20 public UNAS;

    address payable public wallet;
    uint256 public startRate;
    uint256 public start;
    uint256 public step;
    uint256 public round;
    uint256 public refPct;
    uint256 public refMinBuy;
    mapping(uint256 => uint256) public roundSum;
    uint256 public roundSumStep;

    mapping(address => bool) public supportedTokens;
    mapping(address => uint256) public totalsByTokens;
    uint256 public totalsSold;
    uint256 public totalUnclaimed;

    bool private _stopped;

    mapping(address => purchaseInfo[]) private _balances;
    mapping(address => refInfo) private _reffs;
    mapping(address => address) private _user_reff;
    mapping(address => uint256) public totals;
    /**
     * event for token purchase logging
     * @param purchaser who paid & got for the tokens
     * @param valueToken address of token for value amount
     * @param value amount paid for purchase
     * @param amount amount of tokens purchased
     * @param refferal refferal address
     */
    event TokenPurchase(
        address indexed purchaser,
        address indexed valueToken,
        uint256 value,
        uint256 amount,
        address refferal
    );

    event RefWithdraw(address indexed account, uint256 amount);

    constructor(
        address _unas,
        address payable _wallet,
        uint256 _start,
        uint256 _startRate,
        uint256 _step,
        uint256 _roundSum,
        uint256 _refPct,
        uint256 _refMinBuy,
        address[] memory _supportedTokens
    ) {
        require(address(_unas) != address(0));
        require(address(_wallet) != address(0));
        require(_start > 0);
        require(_step > 0);
        require(_refPct > 0);
        require(_refMinBuy > 0);

        UNAS = IERC20(_unas);
        wallet = _wallet;
        startRate = _startRate;
        start = _start;
        step = _step;
        roundSum[round] = _roundSum;
        roundSumStep = _roundSum;
        refPct = _refPct;
        refMinBuy = _refMinBuy;

        for (uint256 index = 0; index < _supportedTokens.length; index++) {
            supportedTokens[_supportedTokens[index]] = true;
        }
    }

    function init_round(uint256 _roundSum, uint256 _round) external onlyOwner nonReentrant {
        require(_roundSum > 0);
        round = _round;
        roundSum[_round] = _roundSum;
    }

    function getCurrentRate() public view returns (uint256) {
        return startRate.add(step.mul(round));
    }

    function availableBalance() public view returns (uint256 balance) {
        balance = UNAS.balanceOf(address(this)).sub(totalUnclaimed);
    }

    function _buy(
        uint256 _value,
        address _token,
        uint256 rateMul,
        address sender,
        bool doTransfer
    ) internal returns (uint256) {
        require(validPurchase(_value, _token), 'not valid purchase');
        IERC20 token = IERC20(_token);
        IERC20Metadata token_meta = IERC20Metadata(_token);
        IERC20Metadata meta = IERC20Metadata(address(UNAS));
        uint256 dec = uint256(10)**uint256(meta.decimals());

        uint256 val = _value.div(uint256(10)**uint256(token_meta.decimals())).mul(dec);
        uint256 r = getCurrentRate().mul(rateMul);
        uint256 amount = val.div(r).mul(dec);

        require(availableBalance() >= amount, 'insufficient tokens balance');

        totalsByTokens[_token] = totalsByTokens[_token].add(_value);
        totalsSold = totalsSold.add(amount);
        if (doTransfer) {
            token.safeTransferFrom(sender, wallet, _value);
        }
        return amount;
    }

    function getRoundRemainder() public view returns (uint256 remainder) {
        remainder = roundSum[round];
    }

    function getTotalPaid(address user) public view returns (uint256 balance) {
        purchaseInfo memory info;
        uint256 dec = uint256(10)**uint256(18);
        for (uint256 i = 0; i < _balances[user].length; i++) {
            info = _balances[user][i];
            IERC20Metadata token = IERC20Metadata(info.valueToken);
            balance += info.value.div(uint256(10)**uint256(token.decimals())).mul(dec);
        }
    }

    function _update_ref(
        address sender,
        uint256 amount,
        address referral
    ) internal {
        uint256 paid = getTotalPaid(referral);
        address ref = referral;
        if (address(referral) == address(0)) {
            ref = _user_reff[sender];
        }

        if (sender != ref && paid >= refMinBuy) {
            _reffs[ref].unclaimed += amount.mul(refPct).div(uint256(1000));
            totalUnclaimed += _reffs[ref].unclaimed;
        }
        for (uint256 i = 0; i < _reffs[ref].users.length; i++) {
            if (_reffs[ref].users[i] == sender) {
                return;
            }
        }
        _reffs[ref].users.push(sender);
        if (address(ref) != address(0)) {
            _user_reff[sender] = ref;
        }
    }

    function _round_purchase(
        uint256 _value,
        address _token,
        address referral,
        address sender,
        uint256 amount
    ) internal {
        _balances[sender].push(purchaseInfo(sender, _token, _value, amount, round, _user_reff[sender]));
        UNAS.safeTransfer(sender, amount);
        emit TokenPurchase(sender, _token, _value, amount, referral);
        if (amount >= roundSum[round]) {
            roundSum[round] = 0;
            round++;
            roundSum[round] = roundSumStep;
        } else {
            roundSum[round] -= amount;
        }
    }

    function buyTokens(
        uint256 _value,
        address _token,
        address referral
    ) external nonReentrant {
        require(_stopped == false, 'stopped');
        address sender = _msgSender();
        uint256 amount = _buy(_value, _token, 1, sender, true);
        _update_ref(sender, amount, referral);
        _round_purchase(_value, _token, referral, sender, amount);
    }

    function buyTokensWithOperator(
        uint256 _value,
        address _token,
        address recipient
    ) external onlyOwner nonReentrant {
        require(_stopped == false, 'stopped');
        uint256 amount = _buy(_value, _token, 1, recipient, false);
        _round_purchase(_value, _token, _user_reff[recipient], recipient, amount);
    }

    function refWithdraw() public nonReentrant {
        require(_stopped == false, 'stopped');
        address account = _msgSender();
        uint256 amount = _reffs[account].unclaimed;
        require(amount > 0, 'Can not withdraw 0');
        totalUnclaimed -= _reffs[account].unclaimed;
        _reffs[account].unclaimed = 0;
        _reffs[account].withdrawn += amount;
        UNAS.safeTransfer(account, amount);
        emit RefWithdraw(account, amount);
    }

    function refInfos(address account) external view returns (refInfo memory) {
        return _reffs[account];
    }

    // return total balance of locked tokens
    function refUnclaimed(address account) external view returns (uint256) {
        return _reffs[account].unclaimed;
    }

    // return total balance of locked tokens
    function refWithdrawn(address account) external view returns (uint256) {
        return _reffs[account].withdrawn;
    }

    // return true if the transaction can buy tokens
    function validPurchase(uint256 value, address token) internal view returns (bool) {
        bool notSmallAmount = value > 0;
        return (notSmallAmount && supportedTokens[token] && block.timestamp > start);
    }

    function updateStartRate(uint256 _startRate) external onlyOwner {
        require(_startRate > 0);
        startRate = _startRate;
    }

    function updateStart(uint256 _start) external onlyOwner {
        require(_start > 0);
        start = _start;
    }

    function updateStep(uint256 _step) external onlyOwner {
        require(_step > 0);
        step = _step;
    }

    function stop() external onlyOwner {
        require(_stopped == false, 'already stopped');
        _stopped = true;
    }

    function emergencyWithdraw(address _token) external onlyOwner nonReentrant {
        IERC20(_token).safeTransfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
