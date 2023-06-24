// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "src/OrbTipping.sol";
import "eric-orb/src/EricOrb.sol";
import "orb/src/OrbPond.sol";

contract OrbTippingBaseTest is Test {
    // Tipping contract
    OrbTipping public orbTipping;

    // Invocations
    string public constant invocation = "What is the meaning of life?";
    bytes32 public constant invocationHash =
        keccak256(abi.encodePacked(invocation));
    string public constant invocation2 = "Who let the dogs out?";
    bytes32 public constant invocation2Hash =
        keccak256(abi.encodePacked(invocation2));

    // Eric Orb
    address public constant ERIC_ORB_ADDRESS =
        address(0xffdAe6724380828178EA290444116BcF5d56cF3D);

    // Addresses
    address public constant tipper = address(0xBEEF);
    address public constant anotherTipper = address(0xBEED);

    // Orb address to test
    address public orbAddress =
        address(0xffdAe6724380828178EA290444116BcF5d56cF3D);

    function setUp() public {
        // Comment one of the two following lines
        // setUpEricOrb(); // Tests Eric Orb
        setUpOrb(); // Tests the new orb

        vm.deal(tipper, 100 ether);
        vm.deal(anotherTipper, 100 ether);

        orbTipping = new OrbTipping();
    }

    // Sets up Eric Orb for testing
    function setUpEricOrb() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 17_485_464);
        orbAddress = address(0xffdAe6724380828178EA290444116BcF5d56cF3D);
    }

    // Sets up the new orb for testing
    function setUpOrb() public {
        vm.startPrank(address(0xCEED));

        Orb orb = new Orb(
            "Orb", // name
            "ORB", // symbol
            69, // tokenId
            address(0xC0FFEE), // beneficiary
            "https://static.orb.land/orb/" // baseURI
        );
        orbAddress = address(orb);
        orb.swearOath(
            keccak256(abi.encodePacked("test oath")), // oathHash
            100, // 1_700_000_000 // honoredUntil
            3600 // responsePeriod
        );
        orb.setAuctionParameters(0.1 ether, 0.1 ether, 1 days, 10 minutes, 5 minutes);
        orb.startAuction();
        vm.deal(address(0xDEED), 100 ether);
        vm.prank(address(0xDEED));
        orb.bid{value: 50 ether}(1.5 ether, 1.5 ether);
        vm.warp(orb.auctionEndTime() + 1000000);
        orb.finalizeAuction();
    }

    function _getOrbKeeper(
        address orbAddress_
    ) internal view returns (address) {
        uint256 tokenId = orbAddress_ == ERIC_ORB_ADDRESS
            ? 69
            : IOrb(orbAddress_).tokenId();

        address orbKeeper = IERC721(orbAddress_).ownerOf(tokenId);

        require(orbKeeper != address(0), "Failed getting orb's keeper");

        return orbKeeper;
    }

    function _getOrbNextInvocationIndex(
        address orbAddress_
    ) internal view returns (uint256) {
        return
            orbAddress_ == ERIC_ORB_ADDRESS
                ? EricOrb(orbAddress_).triggersCount()
                : IOrb(orbAddress_).invocationCount() + 1;
    }

    function _prankAndSuggestInvocation(
        address orbAddress_,
        string memory invocation_
    ) internal {
        vm.prank(_getOrbKeeper(orbAddress_));

        _suggestInvocation(orbAddress_, invocation_);
    }

    function _suggestInvocation(
        address orbAddress_,
        string memory invocation_
    ) internal {
        if (orbAddress_ == ERIC_ORB_ADDRESS) {
            EricOrb(orbAddress_).triggerWithCleartext(invocation_);
        } else {
            IOrb(orbAddress_).invokeWithCleartext(invocation_);
        }
    }
}

contract OrbTippingInvocationSuggesting is OrbTippingBaseTest {
    event InvocationSuggested(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed suggester,
        string invocation
    );

    event InvocationTipped(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed tipper,
        uint256 tipValue
    );

    function testSuggestInvocation() public {
        // Suggest invocation
        vm.expectEmit();
        emit InvocationSuggested(
            orbAddress,
            invocationHash,
            address(this),
            invocation
        );
        orbTipping.suggestInvocation(orbAddress, invocation);

        assertEq(orbTipping.invocations(invocationHash), invocation);
        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 0);
        assertEq(
            orbTipping.tipperTips(address(this), orbAddress, invocationHash),
            0
        );
    }

    function testSuggestInvocationTwice() public {
        // Suggest invocation
        testSuggestInvocation();

        // Suggest the same invocation again
        vm.expectRevert(OrbTipping.InvocationAlreadySuggested.selector);
        orbTipping.suggestInvocation(orbAddress, invocation);
    }

    function testSuggestInvocationWithValue() public {
        // Suggest invocation with tip
        vm.expectEmit();
        emit InvocationSuggested(
            orbAddress,
            invocationHash,
            address(this),
            invocation
        );
        vm.expectEmit();
        emit InvocationTipped(
            orbAddress,
            invocationHash,
            address(this),
            1 ether
        );
        orbTipping.suggestInvocation{value: 1 ether}(orbAddress, invocation);

        assertEq(orbTipping.invocations(invocationHash), invocation);
        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 1 ether);
        assertEq(
            orbTipping.tipperTips(address(this), orbAddress, invocationHash),
            1 ether
        );
    }
}

contract OrbTippingInvocationTipping is OrbTippingBaseTest {
    event InvocationTipped(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed tipper,
        uint256 tipValue
    );

    function testTipInvocation() public {
        // Suggest invocation without tip
        orbTipping.suggestInvocation(orbAddress, invocation);

        // Tip invocation
        vm.expectEmit();
        emit InvocationTipped(
            orbAddress,
            invocationHash,
            address(this),
            1.1 ether
        );
        orbTipping.tipInvocation{value: 1.1 ether}(orbAddress, invocationHash);

        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 1.1 ether);
        assertEq(
            orbTipping.tipperTips(address(this), orbAddress, invocationHash),
            1.1 ether
        );

        // Tip invocation again
        vm.prank(tipper);
        orbTipping.tipInvocation{value: 1.2 ether}(orbAddress, invocationHash);

        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 2.3 ether);
        assertEq(
            orbTipping.tipperTips(tipper, orbAddress, invocationHash),
            1.2 ether
        );
    }
}

contract OrbTippingInvocationTipWithdrawing is OrbTippingBaseTest {
    event TipWithdrawn(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed tipper,
        uint256 tipValue
    );

    function testWithdrawTip() public {
        // Suggest invocation with tip
        vm.startPrank(tipper);
        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);

        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 1.1 ether);
        assertEq(
            orbTipping.tipperTips(address(tipper), orbAddress, invocationHash),
            1.1 ether
        );

        uint256 balanceBeforeWithdraw = address(tipper).balance;

        // Withdraw tip
        vm.expectEmit();
        emit TipWithdrawn(orbAddress, invocationHash, tipper, 1.1 ether);
        orbTipping.withdrawTip(orbAddress, invocationHash);

        uint256 balanceAfterWithdraw = address(tipper).balance;

        assertEq(balanceAfterWithdraw - balanceBeforeWithdraw, 1.1 ether);
        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 0);
        assertEq(
            orbTipping.tipperTips(address(tipper), orbAddress, invocationHash),
            0
        );

        vm.stopPrank();
    }

    function testTwoTippersWithdrawTip() public {
        // Suggest invocation with tip
        vm.prank(tipper);
        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);

        // Tip invocation from a different account
        vm.startPrank(anotherTipper);
        orbTipping.tipInvocation{value: 0.1 ether}(orbAddress, invocationHash);

        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 1.2 ether);
        assertEq(
            orbTipping.tipperTips(address(tipper), orbAddress, invocationHash),
            1.1 ether
        );
        assertEq(
            orbTipping.tipperTips(
                address(anotherTipper),
                orbAddress,
                invocationHash
            ),
            0.1 ether
        );

        uint256 balanceBeforeWithdraw = address(anotherTipper).balance;

        // Withdraw tip from the second tipper
        orbTipping.withdrawTip(orbAddress, invocationHash);

        uint256 balanceAfterWithdraw = address(anotherTipper).balance;

        assertEq(balanceAfterWithdraw - balanceBeforeWithdraw, 0.1 ether);
        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 1.1 ether);
        assertEq(
            orbTipping.tipperTips(
                address(anotherTipper),
                orbAddress,
                invocationHash
            ),
            0
        );

        vm.stopPrank();

        // Withdraw tip from the first tipper
        vm.startPrank(tipper);

        balanceBeforeWithdraw = address(tipper).balance;

        orbTipping.withdrawTip(orbAddress, invocationHash);

        balanceAfterWithdraw = address(tipper).balance;

        assertEq(balanceAfterWithdraw - balanceBeforeWithdraw, 1.1 ether);
        assertEq(orbTipping.totalTips(orbAddress, invocationHash), 0);
        assertEq(
            orbTipping.tipperTips(address(tipper), orbAddress, invocationHash),
            0
        );

        vm.stopPrank();
    }
}

contract OrbTippingTipClaiming is OrbTippingBaseTest {
    event TipsClaimed(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        uint256 tipsValue
    );

    event WithdrawalsBlocked(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        uint256 blockedUntilTimestamp
    );

    event TipWithdrawn(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed tipper,
        uint256 tipValue
    );

    function testClaimTipsForInvocationSuggested() public {
        uint256 invocationIndex = _getOrbNextInvocationIndex(orbAddress);
        address orbKeeper = _getOrbKeeper(orbAddress);

        // Suggest invocation with tip
        vm.startPrank(tipper);

        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);

        // Claim tips (fails because invocation is not suggested yet)
        vm.expectRevert(OrbTipping.InvocationNotSuggested.selector);
        orbTipping.claimTipsForInvocationSuggested(
            orbAddress,
            invocationHash,
            invocationIndex,
            1.1 ether
        );

        // Suggest invocation
        _prankAndSuggestInvocation(orbAddress, invocation);

        uint256 balanceBeforeClaim = address(orbKeeper).balance;

        // Claim tips (fails because `minimumTipValue` is set too high)
        vm.expectRevert(OrbTipping.MinimumTipValueUnavailable.selector);
        orbTipping.claimTipsForInvocationSuggested(
            orbAddress,
            invocationHash,
            invocationIndex,
            1.2 ether
        );

        // Claim tips
        vm.expectEmit();
        emit TipsClaimed(orbAddress, invocationHash, 1.1 ether);
        orbTipping.claimTipsForInvocationSuggested(
            orbAddress,
            invocationHash,
            invocationIndex,
            1.1 ether
        );

        uint256 balanceAfterClaim = address(orbKeeper).balance;

        assertEq(balanceAfterClaim - balanceBeforeClaim, 1.1 ether);

        // Claim tips again (fails because tips are already claimed)
        vm.expectRevert(OrbTipping.TipsAlreadyClaimed.selector);
        orbTipping.claimTipsForInvocationSuggested(
            orbAddress,
            invocationHash,
            invocationIndex,
            0
        );
    }

    function testBlockWithdrawalsNoTipping() public {
        uint256 blockedUntil = block.timestamp + orbTipping.BLOCK_PERIOD();

        // Block withdrawals and tips for an invocation hash
        vm.prank(_getOrbKeeper(orbAddress));
        vm.expectEmit();
        emit WithdrawalsBlocked(orbAddress, invocationHash, blockedUntil);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);

        // Tip (fails because it's blocked)
        vm.prank(tipper);
        vm.expectRevert(OrbTipping.TippingBlockedInvocation.selector);
        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);
    }

    function testBlockWithdrawalsWithMinimumTipValue() public {
        uint256 blockedUntil = block.timestamp + orbTipping.BLOCK_PERIOD();

        // Tip
        vm.prank(tipper);
        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);

        // Block withdrawals and tips for an invocation hash
        // (fails because `minimumTipValue` is set too high)
        vm.startPrank(_getOrbKeeper(orbAddress));
        vm.expectRevert(OrbTipping.MinimumTipValueUnavailable.selector);
        orbTipping.blockWithdrawalsAndTips(
            orbAddress,
            invocationHash,
            1.2 ether
        );

        // Block withdrawals and tips for an invocation hash
        vm.expectEmit();
        emit WithdrawalsBlocked(orbAddress, invocationHash, blockedUntil);
        orbTipping.blockWithdrawalsAndTips(
            orbAddress,
            invocationHash,
            1.1 ether
        );
    }

    function testBlockWithdrawalsOnlyKeeper() public {
        uint256 blockedUntil = block.timestamp + orbTipping.BLOCK_PERIOD();

        // Block withdrawals and tips for an invocation hash from a non-keeper account
        vm.expectRevert(OrbTipping.OnlyOrbKeeperAllowed.selector);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);

        // Block withdrawals and tips for an invocation hash from the keeper's account
        vm.startPrank(_getOrbKeeper(orbAddress));
        vm.expectEmit();
        emit WithdrawalsBlocked(orbAddress, invocationHash, blockedUntil);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);
    }

    function testBlockWithdrawalsCooldown() public {
        uint256 blockTime = block.timestamp;

        // Block withdrawals and tips for an invocation hash
        vm.startPrank(_getOrbKeeper(orbAddress));
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);

        // Block withdrawals and tips for an invocation hash again
        // (fails because of the cooldown period)
        vm.expectRevert(OrbTipping.WithdrawalsBlockingCooldownPending.selector);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);

        vm.warp(blockTime + orbTipping.BLOCKING_COOLDOWN_PERIOD() - 1);

        // Block withdrawals and tips for an invocation hash a moment before the cooldown is over
        // (fails because of the cooldown period)
        vm.expectRevert(OrbTipping.WithdrawalsBlockingCooldownPending.selector);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);

        vm.warp(blockTime + orbTipping.BLOCKING_COOLDOWN_PERIOD());

        // Block withdrawals and tips for an invocation hash again
        // (works because the cooldown period is over)
        uint256 blockedUntil = block.timestamp + orbTipping.BLOCK_PERIOD();
        vm.expectEmit();
        emit WithdrawalsBlocked(orbAddress, invocationHash, blockedUntil);
        orbTipping.blockWithdrawalsAndTips(orbAddress, invocationHash, 0);
    }

    function testBlockWithdrawals() public {
        // Tip
        vm.prank(tipper);
        orbTipping.suggestInvocation{value: 1.1 ether}(orbAddress, invocation);

        // Block withdrawals
        uint256 blockedUntil = block.timestamp + orbTipping.BLOCK_PERIOD();
        vm.prank(_getOrbKeeper(orbAddress));
        orbTipping.blockWithdrawalsAndTips(
            orbAddress,
            invocationHash,
            1.1 ether
        );

        // Attempt to withdraw
        vm.prank(tipper);
        vm.expectRevert(
            OrbTipping.WithdrawalsAreBlockedForThisInvocation.selector
        );
        orbTipping.withdrawTip(orbAddress, invocationHash);

        // Move time forward
        vm.warp(blockedUntil);

        // Attempt to withdraw again
        vm.prank(tipper);
        vm.expectEmit();
        emit TipWithdrawn(orbAddress, invocationHash, tipper, 1.1 ether);
        orbTipping.withdrawTip(orbAddress, invocationHash);
    }
}
