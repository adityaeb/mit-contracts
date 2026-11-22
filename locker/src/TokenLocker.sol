// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TokenLocker — public time locks for any ERC-20 token (MIT "Lock")
/// @notice Anyone can lock any ERC-20 token (a project token, a developer's own buy, a V2-style LP token) until a date,
///         either released all at once or evenly between two dates. A lock can be made longer or larger, never shorter
///         or smaller. It is free: this contract takes no fee.
/// @dev    Rules that cannot change after deployment:
///         - There is NO owner, NO admin, NO upgrade path, NO pause and NO migrate function. The only address that can
///           ever receive a lock's tokens is that lock's owner, and only what the schedule has released.
///         - Every lock keeps its own absolute numbers (`total`, `claimed`); nothing is pooled or shared between locks.
///         - Handing a lock to another wallet takes two steps (propose, then accept) so it cannot be sent to a wrong or
///           hostile address by mistake.
///         - Tokens that take a fee on transfer are credited with what actually arrived.
///         Not supported: tokens whose balances change by themselves (rebasing). Tokens sent straight to this contract
///         without `lock()` belong to no lock and cannot be recovered by anyone.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

contract TokenLocker {
    struct Lock {
        address token;         // the ERC-20 that is locked
        address owner;         // the only wallet that can withdraw, extend, increase or hand over this lock
        address pendingOwner;  // proposed next owner (zero = none); becomes owner only by calling acceptOwner()
        uint128 total;         // every token ever put into this lock
        uint128 claimed;       // tokens already withdrawn
        uint64 createdAt;
        uint64 unlockAt;       // nothing leaves before this moment
        uint64 vestEnd;        // == unlockAt: everything at once. Later: released evenly from unlockAt to vestEnd
        bool permanent;        // true: locked for ever, withdraw() can never work
    }

    uint256 public constant MAX_SPAN = 100 * 365 days;   // furthest a date may be set from now / from unlockAt

    Lock[] private _locks;                                // lock id = index
    mapping(address => uint256[]) private _byToken;       // token => lock ids
    mapping(address => uint256[]) private _byOwner;       // wallet => ids it created or accepted (may no longer own them)
    mapping(address => uint256) public lockedOf;          // token => tokens still inside locks (sum of total - claimed)

    uint256 private _entered = 1;

    event Locked(uint256 indexed id, address indexed token, address indexed owner, uint256 amount, uint64 unlockAt, uint64 vestEnd, string title);
    event Increased(uint256 indexed id, uint256 amount, uint256 total);
    event Extended(uint256 indexed id, uint64 unlockAt, uint64 vestEnd);
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount, uint256 remaining);
    event OwnerProposed(uint256 indexed id, address indexed pendingOwner);
    event OwnerChanged(uint256 indexed id, address indexed previousOwner, address indexed newOwner);
    event MadePermanent(uint256 indexed id);

    error BadToken();
    error BadOwner();
    error BadAmount();
    error BadDates();
    error TitleTooLong();
    error NoSuchLock();
    error NotOwner();
    error NotPendingOwner();
    error NothingToWithdraw();
    error Permanent();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    // ------------------------------------------------------------------ create

    /// @notice Lock `amount` of `token` for `owner`. Needs a prior `approve(this, amount)` on the token.
    /// @param owner    Wallet that will own the lock (usually the caller itself).
    /// @param unlockAt First moment anything can be withdrawn (unix seconds, in the future).
    /// @param vestEnd  Same as `unlockAt` to release everything at once; later to release evenly until then.
    /// @param title    Short public note (at most 64 bytes). Only emitted in the event, never stored.
    /// @return id      The new lock's id.
    function lock(address token, uint256 amount, address owner, uint64 unlockAt, uint64 vestEnd, string calldata title)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (token.code.length == 0) revert BadToken();
        if (owner == address(0) || owner == address(this)) revert BadOwner();
        if (bytes(title).length > 64) revert TitleTooLong();
        _checkDates(unlockAt, vestEnd);
        uint256 received = _pull(token, amount);
        id = _locks.length;
        _locks.push(Lock(token, owner, address(0), uint128(received), 0, uint64(block.timestamp), unlockAt, vestEnd, false));
        _byToken[token].push(id);
        _byOwner[owner].push(id);
        lockedOf[token] += received;
        emit Locked(id, token, owner, received, unlockAt, vestEnd, title);
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice Add more tokens to a lock. They follow the lock's existing dates.
    function increase(uint256 id, uint256 amount) external nonReentrant {
        Lock storage l = _owned(id);
        uint256 received = _pull(l.token, amount);
        uint256 total = uint256(l.total) + received;
        if (total > type(uint128).max) revert BadAmount();
        l.total = uint128(total);
        lockedOf[l.token] += received;
        emit Increased(id, received, total);
    }

    /// @notice Push the dates later. They can never be moved earlier.
    function extend(uint256 id, uint64 unlockAt, uint64 vestEnd) external nonReentrant {
        Lock storage l = _owned(id);
        if (l.permanent) revert Permanent();
        if (unlockAt < l.unlockAt || vestEnd < l.vestEnd || (unlockAt == l.unlockAt && vestEnd == l.vestEnd)) revert BadDates();
        if (vestEnd < unlockAt || unlockAt > block.timestamp + MAX_SPAN || vestEnd - unlockAt > MAX_SPAN) revert BadDates();
        l.unlockAt = unlockAt;
        l.vestEnd = vestEnd;
        emit Extended(id, unlockAt, vestEnd);
    }

    /// @notice Lock the remaining tokens for ever. This cannot be undone.
    function makePermanent(uint256 id) external nonReentrant {
        Lock storage l = _owned(id);
        if (l.permanent) revert Permanent();
        l.permanent = true;
        l.pendingOwner = address(0);
        emit MadePermanent(id);
    }

    /// @notice Withdraw everything the schedule has released so far, to the lock's owner.
    function withdraw(uint256 id) external nonReentrant returns (uint256 amount) {
        Lock storage l = _owned(id);
        amount = _claimable(l);
        if (amount == 0) revert NothingToWithdraw();
        l.claimed += uint128(amount);
        lockedOf[l.token] -= amount;
        _send(l.token, msg.sender, amount);
        emit Withdrawn(id, msg.sender, amount, uint256(l.total) - l.claimed);
    }

    /// @notice Step 1 of handing a lock to another wallet. Zero cancels a pending proposal.
    function proposeOwner(uint256 id, address newOwner) external nonReentrant {
        Lock storage l = _owned(id);
        if (l.permanent) revert Permanent();
        if (newOwner == msg.sender || newOwner == address(this)) revert BadOwner();
        l.pendingOwner = newOwner;
        emit OwnerProposed(id, newOwner);
    }

    /// @notice Step 2: the proposed wallet takes the lock over.
    function acceptOwner(uint256 id) external nonReentrant {
        if (id >= _locks.length) revert NoSuchLock();
        Lock storage l = _locks[id];
        if (msg.sender != l.pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        address previous = l.owner;
        l.owner = msg.sender;
        l.pendingOwner = address(0);
        _byOwner[msg.sender].push(id);
        emit OwnerChanged(id, previous, msg.sender);
    }

    // ------------------------------------------------------------------ views

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLock(uint256 id) external view returns (Lock memory) {
        if (id >= _locks.length) revert NoSuchLock();
        return _locks[id];
    }

    /// @notice Tokens the owner could withdraw right now.
    function claimable(uint256 id) external view returns (uint256) {
        if (id >= _locks.length) revert NoSuchLock();
        return _claimable(_locks[id]);
    }

    /// @notice Tokens the schedule has released so far (withdrawn or not). Zero for a permanent lock.
    function released(uint256 id) external view returns (uint256) {
        if (id >= _locks.length) revert NoSuchLock();
        return _released(_locks[id]);
    }

    function tokenLockCount(address token) external view returns (uint256) {
        return _byToken[token].length;
    }

    function ownerLockCount(address wallet) external view returns (uint256) {
        return _byOwner[wallet].length;
    }

    /// @notice Lock ids of a token, `count` of them from position `start` (paged; never loops over everything).
    function locksOfToken(address token, uint256 start, uint256 count) external view returns (uint256[] memory) {
        return _page(_byToken[token], start, count);
    }

    /// @notice Lock ids a wallet created or accepted. Check `getLock(id).owner` for who owns each one now.
    function locksOfOwner(address wallet, uint256 start, uint256 count) external view returns (uint256[] memory) {
        return _page(_byOwner[wallet], start, count);
    }

    // ------------------------------------------------------------------ internals

    function _owned(uint256 id) private view returns (Lock storage l) {
        if (id >= _locks.length) revert NoSuchLock();
        l = _locks[id];
        if (msg.sender != l.owner) revert NotOwner();
    }

    function _checkDates(uint64 unlockAt, uint64 vestEnd) private view {
        if (unlockAt <= block.timestamp || unlockAt > block.timestamp + MAX_SPAN) revert BadDates();
        if (vestEnd < unlockAt || vestEnd - unlockAt > MAX_SPAN) revert BadDates();
    }

    function _released(Lock storage l) private view returns (uint256) {
        if (l.permanent || block.timestamp < l.unlockAt) return 0;
        if (block.timestamp >= l.vestEnd) return l.total;
        return (uint256(l.total) * (block.timestamp - l.unlockAt)) / (l.vestEnd - l.unlockAt);
    }

    function _claimable(Lock storage l) private view returns (uint256) {
        uint256 r = _released(l);
        return r > l.claimed ? r - l.claimed : 0;        // after extend() the schedule may be behind what was already taken
    }

    /// @dev Pull tokens from the caller and return what actually arrived (so fee-on-transfer tokens are credited correctly).
    function _pull(address token, uint256 amount) private returns (uint256 received) {
        if (amount == 0) revert BadAmount();
        uint256 before = IERC20Balance(token).balanceOf(address(this));
        _call(token, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));   // transferFrom(address,address,uint256)
        received = IERC20Balance(token).balanceOf(address(this)) - before;
        if (received == 0 || received > type(uint128).max) revert BadAmount();
    }

    function _send(address token, address to, uint256 amount) private {
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));                         // transfer(address,uint256)
    }

    /// @dev ERC-20 call that accepts tokens returning nothing (USDT style) and rejects ones returning false.
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _page(uint256[] storage all, uint256 start, uint256 count) private view returns (uint256[] memory out) {
        uint256 n = all.length;
        if (start >= n) return new uint256[](0);
        uint256 end = count > n - start ? n : start + count;   // no overflow, whatever `count` is
        out = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) out[i - start] = all[i];
    }
}
