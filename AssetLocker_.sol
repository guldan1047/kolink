// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract AssetLocker is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public platformFeeRate;
    address public platformFeeReceiver;
    mapping(address user => bool isMnger) public isMnger;
    mapping(string indexCode => LockInfo lockInfo) public orderLockInfo;
    mapping(address user => mapping(address token => uint256 amt)) public userLockedBal;
    mapping(address token => bool lockable) public tokenLockable;

    struct LockInfo {
        address locker;
        address to;
        address token;
        uint256 amt;
        uint256 fee;
        OrderStatus status;
    }

    enum OrderStatus {
        NEW,
        SETTLED,
        CANCELED
    }

    event LockAsset(string _indexCode, address _user, address _to, address _token, uint256 _lockAmt);
    event Settle(string _indexCode, address _to, address _token, uint256 _amt, uint256 _fee);
    event DelegateSettle(string _indexCode, address _locker, address _to, address _token, uint256 _amt, uint256 _fee);
    event CancelLock(string _indexCode, address _locker, address _to, address _token, uint256 _amt);
    event SetTokenLockable(address[] _tokenList, bool[] _flagList);
    event SetPlatformFeeRate(uint256 _oldFeeRate, uint256 _newFeeRate);
    event SetPlatformFeeReceiver(address _oldReceiver, address _newReceiver);
    event SetPlatformMngerList(address[] _mngerList, bool[] _flagList);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "only eoa.");
        _;
    }

    modifier onlyMnger() {
        require(isMnger[msg.sender], "!auth");
        _;
    }

    constructor() {}

    function initialize(
        address[] calldata _tokenList,
        uint256 _platformFeeRate,
        address _platformFeeReceiver,
        address[] calldata _platformMngerList
    ) public initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        for (uint256 i; i < _tokenList.length; i++) {
            require(_tokenList[i] != address(0), "include invalid token.");
            tokenLockable[_tokenList[i]] = true;
        }

        if (_platformFeeRate > 0) {
            require(_platformFeeRate < 1e4, "invalid platformFeeRate.");
            platformFeeRate = _platformFeeRate;
        }

        require(_platformFeeReceiver != address(0), "platformFeeReceiver is zero.");
        platformFeeReceiver = _platformFeeReceiver;

        require(_platformMngerList.length > 0, "need platformMngers");
        for (uint256 i; i < _platformMngerList.length; i++) {
            require(_platformMngerList[i] != address(0), "platformMnger is zero.");
            isMnger[_platformMngerList[i]] = true;
        }
    }

    function lockAsset(string calldata _indexCode, address _to, address _token, uint256 _lockAmt)
        external
        whenNotPaused
        nonReentrant
        onlyEOA
    {
        address user_ = msg.sender;
        bytes memory indexCodeBytes = bytes(_indexCode);
        require(indexCodeBytes.length > 0, "invalid indexCode.");
        require(orderLockInfo[_indexCode].locker == address(0), "indexCode already used.");
        require(_to != address(0) && _to != user_, "invalid _to.");
        require(tokenLockable[_token] == true, "invalid token.");
        require(_lockAmt > 0, "invalid _lockAmt.");
        uint256 fee_;
        if (platformFeeRate > 0) {
            fee_ = _lockAmt * platformFeeRate / (1e4 + platformFeeRate);
        }
        IERC20(_token).safeTransferFrom(user_, address(this), _lockAmt);
        orderLockInfo[_indexCode].locker = user_;
        orderLockInfo[_indexCode].to = _to;
        orderLockInfo[_indexCode].token = _token;
        orderLockInfo[_indexCode].amt = _lockAmt;
        orderLockInfo[_indexCode].fee = fee_;
        orderLockInfo[_indexCode].status = OrderStatus.NEW;
        userLockedBal[user_][_token] += _lockAmt;
        emit LockAsset(_indexCode, user_, _to, _token, _lockAmt);
    }

    function settle(string calldata _indexCode) external whenNotPaused nonReentrant onlyEOA {
        address user_ = msg.sender;
        LockInfo memory lockInfoMemory = orderLockInfo[_indexCode];
        require(user_ == lockInfoMemory.locker, "no auth.");
        require(lockInfoMemory.status == OrderStatus.NEW, "already settled or canceled.");

        orderLockInfo[_indexCode].status = OrderStatus.SETTLED;
        userLockedBal[user_][lockInfoMemory.token] -= lockInfoMemory.amt;

        if (lockInfoMemory.fee > 0) {
            IERC20(lockInfoMemory.token).safeTransfer(platformFeeReceiver, lockInfoMemory.fee);
        }
        IERC20(lockInfoMemory.token).safeTransfer(lockInfoMemory.to, lockInfoMemory.amt - lockInfoMemory.fee);

        emit Settle(_indexCode, lockInfoMemory.to, lockInfoMemory.token, lockInfoMemory.amt, lockInfoMemory.fee);
    }

    function delegateSettle(string[] calldata _indexCodeList) external onlyMnger {
        require(_indexCodeList.length > 0, "invalid param length");
        LockInfo memory lockInfoMemory;
        for (uint256 i; i < _indexCodeList.length; i++) {
            lockInfoMemory = orderLockInfo[_indexCodeList[i]];
            require(lockInfoMemory.locker != address(0), "invalid indexCode.");
            require(lockInfoMemory.status == OrderStatus.NEW, "already settled or canceled.");

            orderLockInfo[_indexCodeList[i]].status = OrderStatus.SETTLED;
            userLockedBal[lockInfoMemory.locker][lockInfoMemory.token] -= lockInfoMemory.amt;

            if (lockInfoMemory.fee > 0) {
                IERC20(lockInfoMemory.token).safeTransfer(platformFeeReceiver, lockInfoMemory.fee);
            }

            IERC20(lockInfoMemory.token).safeTransfer(lockInfoMemory.to, lockInfoMemory.amt - lockInfoMemory.fee);
            emit DelegateSettle(
                _indexCodeList[i],
                lockInfoMemory.locker,
                lockInfoMemory.to,
                lockInfoMemory.token,
                lockInfoMemory.amt,
                lockInfoMemory.fee
            );
        }
    }

    function cancelLock(string calldata _indexCode) external onlyMnger {
        LockInfo memory lockInfoMemory = orderLockInfo[_indexCode];
        require(lockInfoMemory.locker != address(0), "invalid indexCode.");
        require(lockInfoMemory.status == OrderStatus.NEW, "already settled or canceled.");

        orderLockInfo[_indexCode].status = OrderStatus.CANCELED;
        userLockedBal[lockInfoMemory.locker][lockInfoMemory.token] -= lockInfoMemory.amt;
        IERC20(lockInfoMemory.token).safeTransfer(lockInfoMemory.locker, lockInfoMemory.amt);

        emit CancelLock(_indexCode, lockInfoMemory.locker, lockInfoMemory.to, lockInfoMemory.token, lockInfoMemory.amt);
    }

    function setTokenLockable(address[] calldata _tokenList, bool[] calldata _flagList) external onlyMnger {
        require(_tokenList.length > 0 && _tokenList.length == _flagList.length, "param length mismatch.");
        for (uint256 i; i < _tokenList.length; i++) {
            require(_tokenList[i] != address(0), "include invalid token.");
            if (tokenLockable[_tokenList[i]] != _flagList[i]) {
                tokenLockable[_tokenList[i]] = _flagList[i];
            }
        }

        emit SetTokenLockable(_tokenList, _flagList);
    }

    function setPlatformFeeRate(uint256 _newFeeRate) external onlyMnger {
        require(_newFeeRate >= 0 && _newFeeRate < 1e4, "invalid feeRate");
        uint256 oldFeeRate_ = platformFeeRate;
        platformFeeRate = _newFeeRate;

        emit SetPlatformFeeRate(oldFeeRate_, _newFeeRate);
    }

    function setPlatformFeeReceiver(address _newReceiver) external onlyMnger {
        require(_newReceiver != address(0), "invalid newAddr");
        address oldReceiver_ = platformFeeReceiver;
        platformFeeReceiver = _newReceiver;

        emit SetPlatformFeeReceiver(oldReceiver_, _newReceiver);
    }

    function setPlatformManager(address[] calldata _mngerList, bool[] calldata _flagList) external onlyOwner {
        require(_mngerList.length > 0 && _mngerList.length == _flagList.length, "invalid params");

        for (uint256 i; i < _mngerList.length; i++) {
            isMnger[_mngerList[i]] = _flagList[i];
        }

        emit SetPlatformMngerList(_mngerList, _flagList);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _safeTransferETH(address _to, uint256 _value) internal {
        if (_value != 0) {
            (bool success_,) = _to.call{value: _value}(new bytes(0));
            require(success_, "Basic::safeTransferETH: ETH transfer failed");
        }
    }

    function version() external pure returns (string memory) {
        return "v1.0.0";
    }

    receive() external payable {}
}
