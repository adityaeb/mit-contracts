// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenLocker} from "../src/TokenLocker.sol";

interface IERC20Full {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// Runs against REAL tokens on a fork of Robinhood Chain:
///   forge test --match-contract ForkTest --fork-url https://rpc.mainnet.chain.robinhood.com --evm-version cancun
contract ForkTest is Test {
    address constant MIT = 0x219a665FCB5bEeC566052972926b723AD458B43c;      // $MIT (Pons)
    address constant CORBEL = 0xAA1f4De6b9f7cDf11FB8AA97ce163D35D731CdB1;   // another Pons token, already graduated
    TokenLocker lk;
    address dev = address(0xD3F0001);

    function setUp() public {
        if (block.chainid != 4663) return;
        lk = new TokenLocker();
    }

    function _roundtrip(address token, uint256 amount) internal {
        IERC20Full t = IERC20Full(token);
        deal(token, dev, amount);
        vm.startPrank(dev);
        t.approve(address(lk), amount);
        uint256 id = lk.lock(token, amount, dev, uint64(block.timestamp + 30 days), uint64(block.timestamp + 130 days), "dev buy");
        assertEq(t.balanceOf(address(lk)), amount, "no transfer tax: the locker holds exactly what was locked");
        assertEq(lk.getLock(id).total, amount);
        vm.expectRevert(TokenLocker.NothingToWithdraw.selector);
        lk.withdraw(id);
        vm.warp(block.timestamp + 80 days);                  // half of the vesting
        assertEq(lk.withdraw(id), amount / 2);
        vm.warp(block.timestamp + 365 days);
        lk.withdraw(id);
        vm.stopPrank();
        assertEq(t.balanceOf(dev), amount, "everything came back");
        assertEq(t.balanceOf(address(lk)), 0);
        assertEq(lk.lockedOf(token), 0);
    }

    function test_real_mit_lock_vest_and_withdraw() public {
        if (block.chainid != 4663) { emit log("skipped: not a Robinhood Chain fork"); return; }
        _roundtrip(MIT, 10_000_000 ether);
    }

    function test_real_graduated_pons_token() public {
        if (block.chainid != 4663) { emit log("skipped: not a Robinhood Chain fork"); return; }
        _roundtrip(CORBEL, 5_000_000 ether);
    }
}
