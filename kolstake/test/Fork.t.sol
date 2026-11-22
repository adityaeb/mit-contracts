// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KolStake} from "../src/KolStake.sol";

interface IERC20Full {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// Runs against the REAL $MIT token on a fork of Robinhood Chain:  forge test --match-contract ForkTest --fork-url <rpc>
contract ForkTest is Test {
    address constant MIT = 0x219a665FCB5bEeC566052972926b723AD458B43c;
    uint256 constant AMT = 10_000_000 ether;
    KolStake st;
    address kol = address(0xA11CE5);

    function setUp() public {
        if (block.chainid != 4663) return;
        st = new KolStake(MIT, AMT, 30 days);
        deal(MIT, kol, AMT + 5 ether);
    }

    function test_real_mit_stake_and_unstake_roundtrip() public {
        if (block.chainid != 4663) { emit log("skipped: not a Robinhood Chain fork"); return; }
        IERC20Full t = IERC20Full(MIT);
        assertEq(t.balanceOf(kol), AMT + 5 ether);
        vm.startPrank(kol);
        t.approve(address(st), AMT);
        st.stake(keccak256("fork"));
        assertEq(t.balanceOf(address(st)), AMT, "contract holds exactly 10M (no transfer tax)");
        assertEq(t.balanceOf(kol), 5 ether);
        vm.expectRevert(); st.unstake();
        vm.warp(block.timestamp + 30 days);
        st.unstake();
        assertEq(t.balanceOf(kol), AMT + 5 ether, "full amount returned");
        assertEq(t.balanceOf(address(st)), 0);
        vm.stopPrank();
    }

    function test_real_mit_plain_transfer_has_no_tax() public {
        if (block.chainid != 4663) return;
        vm.prank(kol); IERC20Full(MIT).transfer(address(0xBEEF), 1_000 ether);
        assertEq(IERC20Full(MIT).balanceOf(address(0xBEEF)), 1_000 ether);
    }
}
