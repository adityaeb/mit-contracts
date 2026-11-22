// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KolStake — time-locked $MIT stake that qualifies a wallet for the CLS KOL (partner) program
/// @notice A wallet stakes exactly `amount` tokens. The tokens stay in this contract for `lockSeconds`
///         (the cooldown); after that the same wallet can take them back with `unstake()`.
/// @dev    There is NO owner, NO admin, NO upgrade path and NO function that can move a staker's tokens to
///         anyone but that staker. Deploy once; the rules can never change. The CLS backend only READS this
///         contract (the Staked event and `stakes(wallet)`) to switch a KOL code on or off.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract KolStake {
    struct Stake {
        uint128 amount;   // tokens held for this wallet (0 = no stake)
        uint64 since;     // when it was staked
        uint64 unlockAt;  // first moment unstake() works
    }

    address public immutable token;        // the ERC-20 being staked ($MIT)
    uint256 public immutable amount;       // exact number of token units one stake needs
    uint256 public immutable lockSeconds;  // cooldown before unstake() is allowed

    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public stakers;

    uint256 private _entered = 1;

    event Staked(address indexed staker, bytes32 indexed ref, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed staker, uint256 amount);

    error BadConfig();
    error AlreadyStaked();
    error NothingStaked();
    error StillLocked(uint256 unlockAt);
    error TransferFailed();
    error WrongAmountReceived(uint256 received);
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address token_, uint256 amount_, uint256 lockSeconds_) {
        if (token_.code.length == 0 || amount_ == 0 || amount_ > type(uint128).max || lockSeconds_ == 0 || lockSeconds_ > 365 days) {
            revert BadConfig();
        }
        token = token_;
        amount = amount_;
        lockSeconds = lockSeconds_;
    }

    /// @notice Lock exactly `amount` tokens from the caller. Needs a prior `approve(this, amount)` on the token.
    /// @param ref Free 32-byte reference chosen off-chain (the CLS join request id). Only emitted, never stored.
    function stake(bytes32 ref) external nonReentrant {
        if (stakes[msg.sender].amount != 0) revert AlreadyStaked();
        uint256 before = IERC20(token).balanceOf(address(this));
        _call(abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));   // transferFrom(address,address,uint256)
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert WrongAmountReceived(received);                    // fee-on-transfer tokens are refused
        uint64 unlockAt = uint64(block.timestamp + lockSeconds);
        stakes[msg.sender] = Stake(uint128(amount), uint64(block.timestamp), unlockAt);
        totalStaked += amount;
        stakers += 1;
        emit Staked(msg.sender, ref, amount, unlockAt);
    }

    /// @notice Take the caller's own stake back. Only works once the cooldown is over.
    function unstake() external nonReentrant {
        Stake memory s = stakes[msg.sender];
        if (s.amount == 0) revert NothingStaked();
        if (block.timestamp < s.unlockAt) revert StillLocked(s.unlockAt);
        delete stakes[msg.sender];
        totalStaked -= s.amount;
        stakers -= 1;
        _call(abi.encodeWithSelector(0xa9059cbb, msg.sender, uint256(s.amount)));         // transfer(address,uint256)
        emit Unstaked(msg.sender, s.amount);
    }

    /// @notice Seconds left before `wallet` can unstake (0 = can unstake now, or has no stake).
    function cooldownLeft(address wallet) external view returns (uint256) {
        Stake memory s = stakes[wallet];
        if (s.amount == 0 || block.timestamp >= s.unlockAt) return 0;
        return s.unlockAt - block.timestamp;
    }

    /// @dev ERC-20 call that accepts tokens returning nothing (USDT style) and rejects ones returning false.
    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
