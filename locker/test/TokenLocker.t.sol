// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenLocker} from "../src/TokenLocker.sol";

contract Token {
    string public symbol = "TKN";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; totalSupply += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external virtual returns (bool) { _move(msg.sender, to, v); return true; }
    function transferFrom(address f, address to, uint256 v) external virtual returns (bool) {
        allowance[f][msg.sender] -= v; _move(f, to, v); return true;
    }
    function _move(address f, address to, uint256 v) internal virtual { balanceOf[f] -= v; balanceOf[to] += v; }
}

/// 2% of every transfer is burned (a "tax" token)
contract TaxToken is Token {
    function _move(address f, address to, uint256 v) internal override { balanceOf[f] -= v; balanceOf[to] += v - v / 50; totalSupply -= v / 50; }
}

/// returns nothing from transfer / transferFrom (USDT style)
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external { allowance[msg.sender][s] = v; }
    function transfer(address to, uint256 v) external { balanceOf[msg.sender] -= v; balanceOf[to] += v; }
    function transferFrom(address f, address to, uint256 v) external { allowance[f][msg.sender] -= v; balanceOf[f] -= v; balanceOf[to] += v; }
}

/// returns false instead of reverting
contract FalseToken is Token {
    function transferFrom(address, address, uint256) external pure override returns (bool) { return false; }
}

/// tries to call back into the locker while it is being paid out
contract EvilToken is Token {
    TokenLocker public locker;
    uint256 public target;
    bool public armed;
    function arm(TokenLocker l, uint256 id) external { locker = l; target = id; armed = true; }
    function _move(address f, address to, uint256 v) internal override {
        super._move(f, to, v);
        if (armed && f == address(locker)) { armed = false; locker.withdraw(target); }
    }
}

contract TokenLockerTest is Test {
    TokenLocker lk;
    Token tk;
    address dev = address(0xD3F);
    address bob = address(0xB0B);
    address eve = address(0xE7E);
    uint64 t0;

    event Locked(uint256 indexed id, address indexed token, address indexed owner, uint256 amount, uint64 unlockAt, uint64 vestEnd, string title);

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = uint64(block.timestamp);
        lk = new TokenLocker();
        tk = new Token();
        tk.mint(dev, 1_000_000 ether);
        vm.prank(dev);
        tk.approve(address(lk), type(uint256).max);
    }

    function _lock(uint256 amount, uint64 unlockAt, uint64 vestEnd) internal returns (uint256 id) {
        vm.prank(dev);
        id = lk.lock(address(tk), amount, dev, unlockAt, vestEnd, "dev buy");
    }

    // ---------------------------------------------------------------- lock

    function test_lock_holds_tokens_until_the_date_then_returns_all() public {
        vm.expectEmit(true, true, true, true);
        emit Locked(0, address(tk), dev, 1000 ether, t0 + 30 days, t0 + 30 days, "dev buy");
        uint256 id = _lock(1000 ether, t0 + 30 days, t0 + 30 days);
        assertEq(tk.balanceOf(address(lk)), 1000 ether);
        assertEq(lk.lockedOf(address(tk)), 1000 ether);
        assertEq(lk.claimable(id), 0);
        vm.prank(dev);
        vm.expectRevert(TokenLocker.NothingToWithdraw.selector);
        lk.withdraw(id);
        vm.warp(t0 + 30 days - 1);
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 30 days);
        assertEq(lk.claimable(id), 1000 ether);
        uint256 before = tk.balanceOf(dev);
        vm.prank(dev);
        assertEq(lk.withdraw(id), 1000 ether);
        assertEq(tk.balanceOf(dev), before + 1000 ether);
        assertEq(tk.balanceOf(address(lk)), 0);
        assertEq(lk.lockedOf(address(tk)), 0);
        vm.prank(dev);
        vm.expectRevert(TokenLocker.NothingToWithdraw.selector);
        lk.withdraw(id);
    }

    function test_only_the_owner_can_touch_a_lock() public {
        uint256 id = _lock(1000 ether, t0 + 1 days, t0 + 1 days);
        vm.warp(t0 + 2 days);
        vm.startPrank(eve);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.withdraw(id);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.extend(id, t0 + 9 days, t0 + 9 days);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.increase(id, 1);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.makePermanent(id);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.proposeOwner(id, eve);
        vm.expectRevert(TokenLocker.NotPendingOwner.selector); lk.acceptOwner(id);
        vm.stopPrank();
        assertEq(tk.balanceOf(eve), 0);
    }

    function test_lock_for_another_wallet() public {
        vm.prank(dev);
        uint256 id = lk.lock(address(tk), 500 ether, bob, t0 + 1 days, t0 + 1 days, "");
        vm.warp(t0 + 1 days);
        vm.prank(dev);
        vm.expectRevert(TokenLocker.NotOwner.selector);
        lk.withdraw(id);                                   // the payer is not the owner
        vm.prank(bob);
        lk.withdraw(id);
        assertEq(tk.balanceOf(bob), 500 ether);
    }

    function test_bad_inputs_are_refused() public {
        vm.startPrank(dev);
        vm.expectRevert(TokenLocker.BadToken.selector);  lk.lock(address(0xDEAD), 1, dev, t0 + 1, t0 + 1, "");
        vm.expectRevert(TokenLocker.BadOwner.selector);  lk.lock(address(tk), 1, address(0), t0 + 1, t0 + 1, "");
        vm.expectRevert(TokenLocker.BadOwner.selector);  lk.lock(address(tk), 1, address(lk), t0 + 1, t0 + 1, "");
        vm.expectRevert(TokenLocker.BadAmount.selector); lk.lock(address(tk), 0, dev, t0 + 1, t0 + 1, "");
        vm.expectRevert(TokenLocker.BadDates.selector);  lk.lock(address(tk), 1, dev, t0, t0, "");                 // not in the future
        vm.expectRevert(TokenLocker.BadDates.selector);  lk.lock(address(tk), 1, dev, t0 + 10, t0 + 9, "");        // vest ends before it starts
        vm.expectRevert(TokenLocker.BadDates.selector);  lk.lock(address(tk), 1, dev, t0 + 101 * 365 days, t0 + 101 * 365 days, "");
        vm.expectRevert(TokenLocker.TitleTooLong.selector);
        lk.lock(address(tk), 1, dev, t0 + 1, t0 + 1, "0123456789012345678901234567890123456789012345678901234567890123x");
        vm.stopPrank();
        vm.expectRevert(TokenLocker.NoSuchLock.selector); lk.getLock(0);
        vm.expectRevert(TokenLocker.NoSuchLock.selector); lk.claimable(0);
    }

    // ---------------------------------------------------------------- vesting

    function test_vesting_releases_evenly_and_partial_withdrawals_add_up() public {
        uint256 id = _lock(1000 ether, t0 + 10 days, t0 + 110 days);   // 100 days of vesting after a 10 day wait
        vm.warp(t0 + 10 days);
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 35 days);
        assertEq(lk.claimable(id), 250 ether);
        vm.prank(dev); lk.withdraw(id);
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 60 days);
        assertEq(lk.claimable(id), 250 ether);
        assertEq(lk.released(id), 500 ether);
        vm.warp(t0 + 500 days);
        assertEq(lk.claimable(id), 750 ether);
        vm.prank(dev); lk.withdraw(id);
        assertEq(lk.lockedOf(address(tk)), 0);
        assertEq(tk.balanceOf(dev), 1_000_000 ether);
    }

    // ---------------------------------------------------------------- extend / increase / permanent

    function test_dates_only_move_later() public {
        uint256 id = _lock(1000 ether, t0 + 10 days, t0 + 20 days);
        vm.startPrank(dev);
        vm.expectRevert(TokenLocker.BadDates.selector); lk.extend(id, t0 + 9 days, t0 + 20 days);     // earlier unlock
        vm.expectRevert(TokenLocker.BadDates.selector); lk.extend(id, t0 + 10 days, t0 + 19 days);    // earlier end
        vm.expectRevert(TokenLocker.BadDates.selector); lk.extend(id, t0 + 10 days, t0 + 20 days);    // no change
        vm.expectRevert(TokenLocker.BadDates.selector); lk.extend(id, t0 + 30 days, t0 + 25 days);    // end before unlock
        lk.extend(id, t0 + 40 days, t0 + 40 days);
        vm.stopPrank();
        vm.warp(t0 + 39 days);
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 40 days);
        assertEq(lk.claimable(id), 1000 ether);
    }

    function test_extending_after_a_partial_withdrawal_never_gives_tokens_twice() public {
        uint256 id = _lock(1000 ether, t0 + 10 days, t0 + 110 days);
        vm.warp(t0 + 60 days);
        vm.startPrank(dev);
        lk.withdraw(id);                                   // 500 taken
        lk.extend(id, t0 + 100 days, t0 + 300 days);       // schedule now says 0 released
        vm.stopPrank();
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 150 days);                            // new schedule: 250 released, 500 already taken
        assertEq(lk.claimable(id), 0);
        vm.warp(t0 + 250 days);                            // 750 released
        assertEq(lk.claimable(id), 250 ether);
        vm.warp(t0 + 300 days);
        vm.prank(dev); lk.withdraw(id);
        assertEq(tk.balanceOf(dev), 1_000_000 ether);      // exactly what went in, never more
        assertEq(tk.balanceOf(address(lk)), 0);
    }

    function test_increase_adds_to_the_same_lock() public {
        uint256 id = _lock(1000 ether, t0 + 10 days, t0 + 10 days);
        vm.prank(dev); lk.increase(id, 500 ether);
        assertEq(lk.getLock(id).total, 1500 ether);
        assertEq(lk.lockedOf(address(tk)), 1500 ether);
        vm.warp(t0 + 10 days);
        vm.prank(dev); lk.withdraw(id);
        assertEq(tk.balanceOf(address(lk)), 0);
    }

    function test_permanent_lock_can_never_be_withdrawn_or_handed_over() public {
        uint256 id = _lock(1000 ether, t0 + 1 days, t0 + 1 days);
        vm.startPrank(dev);
        lk.makePermanent(id);
        vm.expectRevert(TokenLocker.Permanent.selector); lk.makePermanent(id);
        vm.expectRevert(TokenLocker.Permanent.selector); lk.extend(id, t0 + 2 days, t0 + 2 days);
        vm.expectRevert(TokenLocker.Permanent.selector); lk.proposeOwner(id, bob);
        vm.warp(t0 + 3650 days);
        assertEq(lk.claimable(id), 0);
        vm.expectRevert(TokenLocker.NothingToWithdraw.selector); lk.withdraw(id);
        lk.increase(id, 5 ether);                           // more can still be added
        vm.stopPrank();
        assertEq(lk.lockedOf(address(tk)), 1005 ether);
        assertTrue(lk.getLock(id).permanent);
    }

    // ---------------------------------------------------------------- ownership

    function test_handing_over_takes_two_steps() public {
        uint256 id = _lock(1000 ether, t0 + 1 days, t0 + 1 days);
        vm.prank(dev); lk.proposeOwner(id, bob);
        assertEq(lk.getLock(id).owner, dev);                // nothing changed yet
        vm.prank(eve);
        vm.expectRevert(TokenLocker.NotPendingOwner.selector); lk.acceptOwner(id);
        vm.prank(dev); lk.proposeOwner(id, address(0));     // cancel
        vm.prank(bob);
        vm.expectRevert(TokenLocker.NotPendingOwner.selector); lk.acceptOwner(id);
        vm.prank(dev); lk.proposeOwner(id, bob);
        vm.prank(bob); lk.acceptOwner(id);
        assertEq(lk.getLock(id).owner, bob);
        assertEq(lk.getLock(id).pendingOwner, address(0));
        vm.warp(t0 + 1 days);
        vm.prank(dev);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.withdraw(id);
        vm.prank(bob); lk.withdraw(id);
        assertEq(tk.balanceOf(bob), 1000 ether);
        assertEq(lk.ownerLockCount(bob), 1);
        vm.prank(dev);
        vm.expectRevert(TokenLocker.NotOwner.selector); lk.proposeOwner(id, eve);  // the old owner has no say any more
    }

    function test_cannot_propose_yourself_or_the_locker() public {
        uint256 id = _lock(1 ether, t0 + 1 days, t0 + 1 days);
        vm.startPrank(dev);
        vm.expectRevert(TokenLocker.BadOwner.selector); lk.proposeOwner(id, dev);
        vm.expectRevert(TokenLocker.BadOwner.selector); lk.proposeOwner(id, address(lk));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- awkward tokens

    function test_tax_token_is_credited_with_what_arrived() public {
        TaxToken tax = new TaxToken();
        tax.mint(dev, 1000 ether);
        vm.startPrank(dev);
        tax.approve(address(lk), type(uint256).max);
        uint256 id = lk.lock(address(tax), 1000 ether, dev, t0 + 1 days, t0 + 1 days, "");
        vm.stopPrank();
        assertEq(lk.getLock(id).total, 980 ether);           // 2% never arrived
        assertEq(lk.lockedOf(address(tax)), 980 ether);
        vm.warp(t0 + 1 days);
        vm.prank(dev); lk.withdraw(id);
        assertEq(tax.balanceOf(address(lk)), 0);             // the locker never owes more than it holds
    }

    function test_token_without_return_value_works() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(dev, 100e6);
        vm.startPrank(dev);
        usdt.approve(address(lk), 100e6);
        uint256 id = lk.lock(address(usdt), 100e6, dev, t0 + 1 days, t0 + 1 days, "");
        vm.warp(t0 + 1 days);
        lk.withdraw(id);
        vm.stopPrank();
        assertEq(usdt.balanceOf(dev), 100e6);
    }

    function test_token_returning_false_is_refused() public {
        FalseToken bad = new FalseToken();
        bad.mint(dev, 1 ether);
        vm.startPrank(dev);
        bad.approve(address(lk), 1 ether);
        vm.expectRevert(TokenLocker.TransferFailed.selector);
        lk.lock(address(bad), 1 ether, dev, t0 + 1 days, t0 + 1 days, "");
        vm.stopPrank();
    }

    function test_reentrancy_during_payout_is_blocked() public {
        EvilToken evil = new EvilToken();
        evil.mint(dev, 300 ether);
        vm.startPrank(dev);
        evil.approve(address(lk), type(uint256).max);
        uint256 a = lk.lock(address(evil), 100 ether, dev, t0 + 1 days, t0 + 1 days, "");
        uint256 b = lk.lock(address(evil), 200 ether, dev, t0 + 1 days, t0 + 1 days, "");
        vm.stopPrank();
        vm.warp(t0 + 1 days);
        evil.arm(lk, b);
        vm.prank(dev);
        vm.expectRevert();                                   // the nested withdraw reverts with Reentrancy, the token call fails
        lk.withdraw(a);
        assertEq(evil.balanceOf(address(lk)), 300 ether);    // nothing left the locker
    }

    function test_tokens_sent_directly_do_not_change_any_lock() public {
        uint256 id = _lock(1000 ether, t0 + 1 days, t0 + 1 days);
        vm.prank(dev); tk.transfer(address(lk), 77 ether);   // a mistake: not a lock
        assertEq(lk.lockedOf(address(tk)), 1000 ether);
        vm.warp(t0 + 1 days);
        vm.prank(dev); lk.withdraw(id);
        assertEq(tk.balanceOf(address(lk)), 77 ether);       // stays for ever: nobody can take it
    }

    // ---------------------------------------------------------------- views

    function test_paged_lists() public {
        for (uint256 i = 0; i < 5; i++) _lock(1 ether, t0 + 1 days, t0 + 1 days);
        assertEq(lk.lockCount(), 5);
        assertEq(lk.tokenLockCount(address(tk)), 5);
        uint256[] memory p = lk.locksOfToken(address(tk), 1, 3);
        assertEq(p.length, 3); assertEq(p[0], 1); assertEq(p[2], 3);
        assertEq(lk.locksOfToken(address(tk), 4, 100).length, 1);
        assertEq(lk.locksOfToken(address(tk), 9, 3).length, 0);
        assertEq(lk.locksOfToken(address(tk), 2, type(uint256).max).length, 3);   // no overflow
        assertEq(lk.locksOfOwner(dev, 0, 10).length, 5);
    }

    function test_no_way_to_send_coin_to_the_locker() public {
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        (bool ok,) = address(lk).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_never_pays_more_than_was_locked(uint96 amount, uint32 wait, uint32 vest, uint32[5] memory jumps) public {
        amount = uint96(bound(amount, 1, 1_000_000 ether));
        wait = uint32(bound(wait, 1, 3650 days));
        vest = uint32(bound(vest, 0, 3650 days));
        uint256 id = _lock(amount, t0 + wait, t0 + wait + vest);
        uint256 taken;
        uint256 last;
        for (uint256 i = 0; i < jumps.length; i++) {
            vm.warp(block.timestamp + bound(jumps[i], 0, 3000 days));
            uint256 r = lk.released(id);
            assertGe(r, last, "released never goes down");
            assertLe(r, amount);
            last = r;
            uint256 c = lk.claimable(id);
            if (c > 0) { vm.prank(dev); taken += lk.withdraw(id); }
            assertLe(taken, amount);
            assertEq(lk.lockedOf(address(tk)), amount - taken);
            assertEq(tk.balanceOf(address(lk)), amount - taken);
        }
        vm.warp(uint256(t0) + wait + vest);
        if (lk.claimable(id) > 0) { vm.prank(dev); taken += lk.withdraw(id); }
        assertEq(taken, amount, "everything comes back once the schedule ends");
    }

    function testFuzz_extend_never_unlocks_earlier(uint32 wait, uint32 vest, uint32 addWait, uint32 addVest, uint32 at) public {
        wait = uint32(bound(wait, 1, 1000 days)); vest = uint32(bound(vest, 0, 1000 days));
        addWait = uint32(bound(addWait, 0, 1000 days)); addVest = uint32(bound(addVest, 0, 1000 days));
        vm.assume(addWait + addVest > 0);
        uint256 id = _lock(1000 ether, t0 + wait, t0 + wait + vest);
        uint256 when = uint256(t0) + bound(at, 0, 4000 days);
        uint256 snap = vm.snapshotState();
        vm.warp(when);
        uint256 before = lk.released(id);
        vm.revertToState(snap);
        vm.prank(dev);
        lk.extend(id, t0 + wait + addWait, t0 + wait + addWait + vest + addVest);
        vm.warp(when);
        assertLe(lk.released(id), before, "a later schedule never releases more at the same moment");
    }
}

/// Random sequences of every action by several wallets: the locker must always hold at least what its locks say.
contract Handler is Test {
    TokenLocker public lk;
    Token public tk;
    address[3] public who = [address(0xA1), address(0xA2), address(0xA3)];
    uint256 public put;
    uint256 public out;

    constructor(TokenLocker l, Token t) {
        lk = l; tk = t;
        for (uint256 i = 0; i < 3; i++) { tk.mint(who[i], 1e30); vm.prank(who[i]); tk.approve(address(lk), type(uint256).max); }
    }

    function lock(uint256 w, uint96 amount, uint32 wait, uint32 vest) external {
        address a = who[w % 3];
        amount = uint96(bound(amount, 1, 1e24));
        vm.prank(a);
        lk.lock(address(tk), amount, who[(w / 3) % 3], uint64(block.timestamp + bound(wait, 1, 400 days)), uint64(block.timestamp + bound(wait, 1, 400 days) + bound(vest, 0, 400 days)), "");
        put += amount;
    }

    function increase(uint256 id, uint96 amount) external {
        uint256 n = lk.lockCount(); if (n == 0) return;
        id = id % n; amount = uint96(bound(amount, 1, 1e24));
        vm.prank(lk.getLock(id).owner);
        lk.increase(id, amount);
        put += amount;
    }

    function withdraw(uint256 id) external {
        uint256 n = lk.lockCount(); if (n == 0) return;
        id = id % n;
        if (lk.claimable(id) == 0) return;
        vm.prank(lk.getLock(id).owner);
        out += lk.withdraw(id);
    }

    function extend(uint256 id, uint32 a, uint32 b) external {
        uint256 n = lk.lockCount(); if (n == 0) return;
        id = id % n;
        TokenLocker.Lock memory l = lk.getLock(id);
        if (l.permanent) return;
        uint64 u = l.unlockAt + uint64(bound(a, 0, 100 days));
        uint64 e = l.vestEnd + uint64(bound(b, 1, 100 days));
        if (e < u) e = u;
        if (u > block.timestamp + lk.MAX_SPAN() || e - u > lk.MAX_SPAN()) return;
        vm.prank(l.owner);
        lk.extend(id, u, e);
    }

    function permanent(uint256 id) external {
        uint256 n = lk.lockCount(); if (n == 0) return;
        id = id % n;
        TokenLocker.Lock memory l = lk.getLock(id);
        if (l.permanent || id % 7 != 0) return;             // only some, or nothing would ever be withdrawn
        vm.prank(l.owner);
        lk.makePermanent(id);
    }

    function handOver(uint256 id, uint256 w) external {
        uint256 n = lk.lockCount(); if (n == 0) return;
        id = id % n;
        TokenLocker.Lock memory l = lk.getLock(id);
        address to = who[w % 3];
        if (l.permanent || to == l.owner) return;
        vm.prank(l.owner); lk.proposeOwner(id, to);
        vm.prank(to); lk.acceptOwner(id);
    }

    function wait(uint32 s) external { vm.warp(block.timestamp + bound(s, 1, 200 days)); }
}

contract TokenLockerInvariant is Test {
    TokenLocker lk;
    Token tk;
    Handler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        lk = new TokenLocker();
        tk = new Token();
        h = new Handler(lk, tk);
        targetContract(address(h));
    }

    function invariant_locker_holds_exactly_what_its_locks_say() public view {
        assertEq(tk.balanceOf(address(lk)), lk.lockedOf(address(tk)));
        assertEq(lk.lockedOf(address(tk)), h.put() - h.out());
        uint256 sum;
        uint256 n = lk.lockCount();
        for (uint256 i = 0; i < n; i++) {
            TokenLocker.Lock memory l = lk.getLock(i);
            assertLe(l.claimed, l.total);
            assertLe(lk.claimable(i), uint256(l.total) - l.claimed);
            sum += uint256(l.total) - l.claimed;
        }
        assertEq(sum, lk.lockedOf(address(tk)));
    }
}
