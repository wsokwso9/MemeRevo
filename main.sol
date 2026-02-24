// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Pepperjack variant #7 — originally designed for cross-chain burn auctions; adapted for single-chain meme consolidation.
 * MemeRevo: meme revolution platform with inferno burn mechanics and tiered collectiva membership.
 * @dev Vault, treasury, burnPool, and referralHub are immutable; guardian is rotatable. ReentrancyGuard and Pausable for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20Meme {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract MemeRevo is ReentrancyGuard, Pausable, Ownable {

    event TokenInferno(address indexed token, address indexed from, uint256 amountBurned, uint256 ethOut, uint256 atBlock);
    event TierAscended(address indexed member, uint8 tierId, uint256 paidWei, uint256 atBlock);
    event ReferralCredited(address indexed referrer, address indexed referred, uint256 amountWei, uint256 atBlock);
    event BurnPoolToEth(uint256 tokenAmountBurned, uint256 ethReceived, uint256 atBlock);
    event VaultHarvest(address indexed to, uint256 amountWei, uint256 atBlock);
    event TreasuryHarvest(address indexed to, uint256 amountWei, uint256 atBlock);
    event CollectivaPaused(bool paused, uint256 atBlock);
    event MemeTokenWhitelisted(address indexed token, bool allowed, uint256 atBlock);
    event TierConfigUpdated(uint8 indexed tierId, uint256 joinPriceWei, uint256 shareBps, uint256 atBlock);
    event GuardianRotated(address indexed previous, address indexed newGuardian, uint256 atBlock);
    event MinBurnAmountUpdated(uint256 previous, uint256 current, uint256 atBlock);
    event MaxBurnPerTxUpdated(uint256 previous, uint256 current, uint256 atBlock);
    event ReferralBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event MemberJoined(address indexed member, uint8 tierId, address indexed referrer, uint256 atBlock);
    event PayoutDistributed(address indexed to, uint8 tierId, uint256 amountWei, uint256 atBlock);
    event InfernoBatch(address indexed from, uint256 tokenCount, uint256 totalBurned, uint256 atBlock);
    event TierDeactivated(uint8 indexed tierId, uint256 atBlock);
    event TierActivated(uint8 indexed tierId, uint256 atBlock);
    event NonceMarkedUsed(bytes32 indexed nonce, address by, uint256 atBlock);
    event BurnStatsUpdated(address indexed user, address indexed token, uint256 amount, uint256 atBlock);
    event SnapshotRecorded(uint256 indexed snapshotId, uint8 tierId, uint256 memberCount, uint256 atBlock);
    event ConfigFrozen(uint256 atBlock);
    event MinJoinWeiEnforced(uint256 value, uint256 atBlock);
    event MaxJoinWeiEnforced(uint256 value, uint256 atBlock);

    error MRV_ZeroAddress();
    error MRV_ZeroAmount();
