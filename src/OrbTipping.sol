// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IOrb} from "orb/src/IOrb.sol";
import {EricOrb} from "eric-orb/src/EricOrb.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "forge-std/console2.sol";

contract OrbTipping {
    ////////////////////////////////////////////////////////////////////////////////
    //  STORAGE
    ////////////////////////////////////////////////////////////////////////////////

    // STATE VARIABLES

    /// The sum of all tips for a given invocation
    mapping(address => mapping(bytes32 => uint256)) public totalTips;

    /// The sum of all tips for a given invocation by a given tipper
    mapping(address => mapping(address => mapping(bytes32 => uint256)))
        public tipperTips;

    /// The invocation cleartext string for a given invocation hash
    mapping(bytes32 => string) public invocations;

    /// Whether a certain invocation's tips have been claimed
    mapping(address => mapping(bytes32 => bool)) public claimedInvocations;

    /// The timestamp until which withdrawals are blocked for a given invocation
    mapping(address => mapping(bytes32 => uint256)) public blockedInvocations;

    // CONSTANTS

    /// The "first generation" orb contract that doesn't have the same ABI as the new orbs
    /// created from the new Orb Pond (factory contract)
    address public constant SPECIAL_ORIC_ORB =
        address(0xffdAe6724380828178EA290444116BcF5d56cF3D);

    /// The period of time during which withdrawals are blocked after an orb keeper calls `blockWithdrawals`
    uint256 public constant BLOCK_PERIOD = 15 minutes;

    /// The period of time during which `blockWithdrawals` can't be called again after calling
    /// it for a specific invocation
    uint256 public constant BLOCKING_COOLDOWN_PERIOD = 1 days;

    ////////////////////////////////////////////////////////////////////////////////
    //  ERRORS
    ////////////////////////////////////////////////////////////////////////////////
    error InvocationAlreadySuggested();
    error InvocationTooLong();
    error InvocationNotFound();
    error InvocationWasAnswered();
    error InvocationNotSuggested();
    error TipCantBeZero();
    error NoClaimableTip();
    error TipNotFound();
    error TipsAlreadyClaimed();
    error InvalidInvocationHash();
    error InvalidOrbKeeper();
    error OnlyOrbKeeperAllowed();
    error WithdrawalsAreBlockedForThisInvocation();
    error WithdrawalsBlockingCooldownPending();
    error TippingBlockedInvocation();
    error MinimumTipValueUnavailable();

    ////////////////////////////////////////////////////////////////////////////////
    //  EVENTS
    ////////////////////////////////////////////////////////////////////////////////
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
    event TipsClaimed(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        uint256 tipsValue
    );
    event TipWithdrawn(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        address indexed tipper,
        uint256 tipValue
    );
    event WithdrawalsBlocked(
        address indexed orbAddress,
        bytes32 indexed invocationHash,
        uint256 blockedUntilTimestamp
    );

    ////////////////////////////////////////////////////////////////////////////////
    //  FUNCTIONS: Invocation Submission & Tipping
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Suggests an invocation request to the Orb Tipping contract, optionally with a tip
    /// @param orbAddress The address of the orb to which the invocation is being suggested
    /// @param invocation The invocation's content string
    function suggestInvocation(
        address orbAddress,
        string memory invocation
    ) public payable {
        bytes32 invocationHash = keccak256(abi.encodePacked(invocation));

        if (bytes(invocations[invocationHash]).length != 0) {
            revert InvocationAlreadySuggested();
        }

        if (bytes(invocation).length > _getOrbMaxInvocationLength(orbAddress)) {
            revert InvocationTooLong();
        }

        invocations[invocationHash] = invocation;

        emit InvocationSuggested(
            orbAddress,
            invocationHash,
            msg.sender,
            invocation
        );

        if (msg.value > 0) {
            _tipInvocation(orbAddress, invocationHash);
        }
    }

    /// @notice Tips an orb keeper to invoke their orb with a specific content hash
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    function tipInvocation(
        address orbAddress,
        bytes32 invocationHash
    ) public payable {
        _tipInvocation(orbAddress, invocationHash);
    }

    ////////////////////////////////////////////////////////////////////////////////
    //  FUNCTIONS: Claiming & Withdrawing Tips
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Claims all tips for a given invocation that has been suggested
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    /// @param invocationIndex The invocation index to check
    /// @param minimumTipValue The minimum tip value to claim (reverts if the total tips are less than this value)
    function claimTipsForInvocationSuggested(
        address orbAddress,
        bytes32 invocationHash,
        uint256 invocationIndex,
        uint256 minimumTipValue
    ) public {
        uint256 totalClaimableTips = totalTips[orbAddress][invocationHash];
        address currentOrbKeeper = _getOrbKeeper(orbAddress);

        if (claimedInvocations[orbAddress][invocationHash]) {
            revert TipsAlreadyClaimed();
        }

        if (totalClaimableTips == 0) {
            revert NoClaimableTip();
        }

        if (totalClaimableTips < minimumTipValue) {
            revert MinimumTipValueUnavailable();
        }

        if (
            !_wasInvocationSuggested(
                orbAddress,
                invocationHash,
                invocationIndex
            )
        ) {
            revert InvocationNotSuggested();
        }

        claimedInvocations[orbAddress][invocationHash] = true;
        payable(currentOrbKeeper).transfer(totalClaimableTips);

        emit TipsClaimed(orbAddress, invocationHash, totalClaimableTips);
    }

    /// @notice Blocks withdrawals and tips for a given invocation for the duration of `WITHDRAWAL_BLOCK_PERIOD`
    /// @dev Can only be called by the orb keeper. Can not be called again for the same invocation for `BLOCKING_COOLDOWN_PERIOD`
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    /// @param minimumTipValue The minimum tip value to claim (reverts if the total tips are less than this value)
    function blockWithdrawalsAndTips(
        address orbAddress,
        bytes32 invocationHash,
        uint256 minimumTipValue
    ) public {
        if (msg.sender != _getOrbKeeper(orbAddress)) {
            revert OnlyOrbKeeperAllowed();
        }

        if (
            blockedInvocations[orbAddress][invocationHash] +
                BLOCKING_COOLDOWN_PERIOD -
                BLOCK_PERIOD >
            block.timestamp
        ) {
            revert WithdrawalsBlockingCooldownPending();
        }

        if (totalTips[orbAddress][invocationHash] < minimumTipValue) {
            revert MinimumTipValueUnavailable();
        }

        uint256 withdrawalsBlockedUntil = block.timestamp + BLOCK_PERIOD;

        blockedInvocations[orbAddress][
            invocationHash
        ] = withdrawalsBlockedUntil;

        emit WithdrawalsBlocked(
            orbAddress,
            invocationHash,
            withdrawalsBlockedUntil
        );
    }

    /// @notice Withdraws a tip previously suggested for a given invocation
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    function withdrawTip(address orbAddress, bytes32 invocationHash) public {
        uint256 tipValue = tipperTips[msg.sender][orbAddress][invocationHash];

        if (tipValue == 0) {
            revert TipNotFound();
        }

        if (claimedInvocations[orbAddress][invocationHash]) {
            revert InvocationWasAnswered();
        }

        if (blockedInvocations[orbAddress][invocationHash] > block.timestamp) {
            revert WithdrawalsAreBlockedForThisInvocation();
        }

        totalTips[orbAddress][invocationHash] -= tipValue;
        tipperTips[msg.sender][orbAddress][invocationHash] = 0;

        payable(msg.sender).transfer(tipValue);

        emit TipWithdrawn(orbAddress, invocationHash, msg.sender, tipValue);
    }

    /// @notice Withdraws a tips previously suggested for a given list of invocation
    /// @param orbAddresses_ Array of orb addresse
    /// @param invocationHashes_ Array of invocation content hashes
    function withdrawTips(
        address[] memory orbAddresses_,
        bytes32[] memory invocationHashes_
    ) public {
        for (uint256 index = 0; index < orbAddresses_.length; index++) {
            withdrawTip(orbAddresses_[index], invocationHashes_[index]);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    //  INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Gets the address of an orb's current keeper
    /// @param orbAddress The address of the orb
    function _getOrbKeeper(address orbAddress) internal view returns (address) {
        uint256 tokenId = orbAddress == SPECIAL_ORIC_ORB
            ? 69
            : IOrb(orbAddress).tokenId();

        address orbKeeper = IERC721(orbAddress).ownerOf(tokenId);

        if (orbKeeper == address(0)) {
            revert InvalidOrbKeeper();
        }

        return orbKeeper;
    }

    /// @notice Gets the maximum length of an invocation for a given orb
    /// @param orbAddress The address of the orb
    function _getOrbMaxInvocationLength(
        address orbAddress
    ) internal view returns (uint256) {
        if (orbAddress == SPECIAL_ORIC_ORB) {
            return 280;
        }

        return IOrb(orbAddress).cleartextMaximumLength();
    }

    /// @notice Checks if a specific content hash was invoked for a given orb and invocation index
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    /// @param invocationIndex The invocation index to check
    function _wasInvocationSuggested(
        address orbAddress,
        bytes32 invocationHash,
        uint256 invocationIndex
    ) internal view returns (bool) {
        if (orbAddress == SPECIAL_ORIC_ORB) {
            return
                EricOrb(orbAddress).triggers(invocationIndex) == invocationHash;
        } else {
            (, bytes32 contentHash, ) = IOrb(orbAddress).invocations(
                invocationIndex
            );
            return contentHash == invocationHash;
        }
    }

    /// @notice Tips an orb keeper to invoke their orb with a specific content hash
    /// @param orbAddress The address of the orb
    /// @param invocationHash The invocation content hash
    function _tipInvocation(
        address orbAddress,
        bytes32 invocationHash
    ) internal {
        if (invocationHash == bytes32(0)) {
            revert InvalidInvocationHash();
        }

        if (msg.value == 0) {
            revert TipCantBeZero();
        }

        if (bytes(invocations[invocationHash]).length == 0) {
            revert InvocationNotFound();
        }

        if (blockedInvocations[orbAddress][invocationHash] > block.timestamp) {
            revert TippingBlockedInvocation();
        }

        totalTips[orbAddress][invocationHash] += msg.value;
        tipperTips[msg.sender][orbAddress][invocationHash] += msg.value;

        emit InvocationTipped(
            orbAddress,
            invocationHash,
            msg.sender,
            msg.value
        );
    }
}
