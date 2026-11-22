// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KolStake} from "../src/KolStake.sol";

contract Tok {
    string public name = "T";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) public virtual returns (bool) { _move(msg.sender, to, v); return true; }
    function transferFrom(address f, address to, uint256 v) public virtual returns (bool) {
        allowance[f][msg.sender] -= v; _move(f, to, v); return true;
    }
    function _move(address f, address to, uint256 v) internal virtual { balanceOf[f] -= v; balanceOf[to] += v; }
}

contract FeeTok is Tok {                       // 1% burned on every move
    function _move(address f, address to, uint256 v) internal override { balanceOf[f] -= v; balanceOf[to] += v - v / 100; }
}

contract FalseTok is Tok {                     // returns false instead of reverting
    function transferFrom(address, address, uint256) public pure override returns (bool) { return false; }
}

contract NoReturnTok {                         // USDT style: no return value
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external { allowance[msg.sender][s] = v; }
    function transfer(address to, uint256 v) external { balanceOf[msg.sender] -= v; balanceOf[to] += v; }
    function transferFrom(address f, address to, uint256 v) external { allowance[f][msg.sender] -= v; balanceOf[f] -= v; balanceOf[to] += v; }
}

contract ReenterTok is Tok {                   // tries to re-enter the stake contract while tokens move out
    KolStake public target;
    bool public armed;
    function arm(KolStake t) external { target = t; armed = true; }
    function transfer(address to, uint256 v) public override returns (bool) {
        if (armed) { armed = false; target.unstake(); }
        return super.transfer(to, v);
    }
}

contract KolStakeTest is Test {
    uint256 constant AMT = 10_000_000 ether;
    uint256 constant LOCK = 30 days;
    Tok tok;
    KolStake st;
    address kol = address(0xA11CE);
    address other = address(0xB0B);

    event Staked(address indexed staker, bytes32 indexed ref, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed staker, uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        tok = new Tok();
        st = new KolStake(address(tok), AMT, LOCK);
        tok.mint(kol, AMT * 3);
        tok.mint(other, AMT);
        vm.prank(kol); tok.approve(address(st), type(uint256).max);
        vm.prank(other); tok.approve(address(st), type(uint256).max);
    }

    function test_config() public view {
        assertEq(st.token(), address(tok)); assertEq(st.amount(), AMT); assertEq(st.lockSeconds(), LOCK);
    }

    function test_bad_config_reverts() public {
        vm.expectRevert(KolStake.BadConfig.selector); new KolStake(address(0x1234), AMT, LOCK);       // not a contract
        vm.expectRevert(KolStake.BadConfig.selector); new KolStake(address(tok), 0, LOCK);
        vm.expectRevert(KolStake.BadConfig.selector); new KolStake(address(tok), AMT, 0);
        vm.expectRevert(KolStake.BadConfig.selector); new KolStake(address(tok), AMT, 366 days);
        vm.expectRevert(KolStake.BadConfig.selector); new KolStake(address(tok), uint256(type(uint128).max) + 1, LOCK);
    }

    function test_stake_locks_exact_amount_and_emits() public {
        bytes32 ref = keccak256("join-1");
        vm.expectEmit(true, true, false, true, address(st));
        emit Staked(kol, ref, AMT, block.timestamp + LOCK);
        vm.prank(kol); st.stake(ref);
        (uint128 a, uint64 since, uint64 unlockAt) = st.stakes(kol);
        assertEq(a, AMT); assertEq(since, block.timestamp); assertEq(unlockAt, block.timestamp + LOCK);
        assertEq(tok.balanceOf(address(st)), AMT); assertEq(tok.balanceOf(kol), AMT * 2);
        assertEq(st.totalStaked(), AMT); assertEq(st.stakers(), 1); assertEq(st.cooldownLeft(kol), LOCK);
    }

    function test_cannot_stake_twice() public {
        vm.startPrank(kol); st.stake(0);
        vm.expectRevert(KolStake.AlreadyStaked.selector); st.stake(0);
    }

    function test_stake_needs_allowance_and_balance() public {
        address poor = address(0xDEAD1);
        vm.prank(poor); tok.approve(address(st), type(uint256).max);
        vm.prank(poor); vm.expectRevert(KolStake.TransferFailed.selector); st.stake(0);                // no balance
        tok.mint(poor, AMT); vm.prank(poor); tok.approve(address(st), AMT - 1);
        vm.prank(poor); vm.expectRevert(KolStake.TransferFailed.selector); st.stake(0);                // allowance too low
    }

    function test_unstake_blocked_until_cooldown_ends() public {
        vm.prank(kol); st.stake(0);
        uint256 unlockAt = block.timestamp + LOCK;
        vm.prank(kol); vm.expectRevert(abi.encodeWithSelector(KolStake.StillLocked.selector, unlockAt)); st.unstake();
        vm.warp(unlockAt - 1);
        vm.prank(kol); vm.expectRevert(abi.encodeWithSelector(KolStake.StillLocked.selector, unlockAt)); st.unstake();
        assertEq(st.cooldownLeft(kol), 1);
        vm.warp(unlockAt);
        assertEq(st.cooldownLeft(kol), 0);
        vm.expectEmit(true, false, false, true, address(st)); emit Unstaked(kol, AMT);
        vm.prank(kol); st.unstake();
        assertEq(tok.balanceOf(kol), AMT * 3); assertEq(tok.balanceOf(address(st)), 0);
        (uint128 a,,) = st.stakes(kol); assertEq(a, 0); assertEq(st.totalStaked(), 0); assertEq(st.stakers(), 0);
    }

    function test_unstake_without_stake_reverts() public {
        vm.prank(other); vm.expectRevert(KolStake.NothingStaked.selector); st.unstake();
    }

    function test_nobody_else_can_take_a_stake() public {
        vm.prank(kol); st.stake(0);
        vm.warp(block.timestamp + LOCK + 1);
        vm.prank(other); vm.expectRevert(KolStake.NothingStaked.selector); st.unstake();              // other has no stake of their own
        assertEq(tok.balanceOf(address(st)), AMT);
        vm.prank(other); st.stake(0);                                                                // two stakers, funds kept apart
        vm.prank(kol); st.unstake();
        assertEq(tok.balanceOf(address(st)), AMT); (uint128 b,,) = st.stakes(other); assertEq(b, AMT);
    }

    function test_restake_starts_a_new_cooldown() public {
        vm.startPrank(kol); st.stake(0);
        vm.warp(block.timestamp + LOCK); st.unstake();
        st.stake(bytes32(uint256(2)));
        (, , uint64 unlockAt) = st.stakes(kol); assertEq(unlockAt, block.timestamp + LOCK);
        vm.expectRevert(abi.encodeWithSelector(KolStake.StillLocked.selector, uint256(unlockAt))); st.unstake();
    }

    function test_stake_stays_valid_after_cooldown_until_unstaked() public {
        vm.prank(kol); st.stake(0);
        vm.warp(block.timestamp + 400 days);
        (uint128 a,,) = st.stakes(kol); assertEq(a, AMT); assertEq(st.cooldownLeft(kol), 0);
    }

    function test_fee_on_transfer_token_is_refused() public {
        FeeTok f = new FeeTok(); KolStake s2 = new KolStake(address(f), AMT, LOCK);
        f.mint(kol, AMT * 2); vm.startPrank(kol); f.approve(address(s2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KolStake.WrongAmountReceived.selector, AMT - AMT / 100)); s2.stake(0);
    }

    function test_token_returning_false_is_refused() public {
        FalseTok f = new FalseTok(); KolStake s2 = new KolStake(address(f), AMT, LOCK);
        f.mint(kol, AMT); vm.startPrank(kol); f.approve(address(s2), type(uint256).max);
        vm.expectRevert(KolStake.TransferFailed.selector); s2.stake(0);
    }

    function test_token_without_return_value_works() public {
        NoReturnTok n = new NoReturnTok(); KolStake s2 = new KolStake(address(n), AMT, LOCK);
        n.mint(kol, AMT); vm.startPrank(kol); n.approve(address(s2), AMT); s2.stake(0);
        vm.warp(block.timestamp + LOCK); s2.unstake(); assertEq(n.balanceOf(kol), AMT);
    }

    function test_reentrancy_is_blocked() public {
        ReenterTok r = new ReenterTok(); KolStake s2 = new KolStake(address(r), AMT, LOCK);
        r.mint(kol, AMT); vm.startPrank(kol); r.approve(address(s2), AMT); s2.stake(0);
        vm.warp(block.timestamp + LOCK); r.arm(s2);
        vm.expectRevert(KolStake.TransferFailed.selector); s2.unstake();                              // inner unstake reverts -> transfer fails
        (uint128 a,,) = s2.stakes(kol); assertEq(a, AMT); assertEq(r.balanceOf(address(s2)), AMT);    // nothing lost
    }

    function test_contract_has_no_way_out_for_third_parties() public {
        vm.prank(kol); st.stake(0);
        // every external function, called by a stranger, leaves the staker's tokens where they are
        vm.startPrank(address(0xBAD));
        vm.expectRevert(); st.unstake();
        vm.expectRevert(); st.stake(0);
        (bool ok,) = address(st).call(abi.encodeWithSignature("withdraw(address,uint256)", address(0xBAD), AMT)); assertFalse(ok);
        (ok,) = address(st).call{value: 0}(""); assertFalse(ok);
        vm.stopPrank();
        assertEq(tok.balanceOf(address(st)), AMT);
    }

    function testFuzz_unstake_only_after_lock(uint32 wait) public {
        vm.prank(kol); st.stake(0);
        uint256 t0 = block.timestamp; vm.warp(t0 + wait);
        vm.prank(kol);
        if (wait < LOCK) { vm.expectRevert(abi.encodeWithSelector(KolStake.StillLocked.selector, t0 + LOCK)); st.unstake(); }
        else { st.unstake(); assertEq(tok.balanceOf(kol), AMT * 3); }
    }

    function testFuzz_many_stakers_accounting(uint8 n) public {
        n = uint8(bound(n, 1, 40));
        for (uint256 i = 1; i <= n; i++) {
            address a = address(uint160(0x1000 + i)); tok.mint(a, AMT);
            vm.startPrank(a); tok.approve(address(st), AMT); st.stake(bytes32(i)); vm.stopPrank();
        }
        assertEq(st.totalStaked(), AMT * n); assertEq(tok.balanceOf(address(st)), AMT * n); assertEq(st.stakers(), n);
        vm.warp(block.timestamp + LOCK);
        for (uint256 i = 1; i <= n; i++) { address a = address(uint160(0x1000 + i)); vm.prank(a); st.unstake(); assertEq(tok.balanceOf(a), AMT); }
        assertEq(st.totalStaked(), 0); assertEq(tok.balanceOf(address(st)), 0);
    }
}
