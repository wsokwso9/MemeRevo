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
    error MRV_CollectivaPaused();
    error MRV_TokenNotWhitelisted();
    error MRV_TransferFailed();
    error MRV_Reentrancy();
    error MRV_NotGuardian();
    error MRV_InvalidTier();
    error MRV_InvalidShareBps();
    error MRV_InvalidReferralBps();
    error MRV_InsufficientPayment();
    error MRV_AlreadyMember();
    error MRV_NotMember();
    error MRV_AmountBelowMin();
    error MRV_AmountAboveMax();
    error MRV_ArrayLengthMismatch();
    error MRV_BatchTooLarge();
    error MRV_NoBalance();
    error MRV_InvalidAmount();
    error MRV_ApprovalFailed();
    error MRV_SameAddress();
    error MRV_InvalidBps();
    error MRV_NoEthReceived();
    error MRV_GuardianOnly();

    uint256 public constant MRV_BPS_BASE = 10000;
    uint256 public constant MRV_MAX_TIERS = 8;
    uint256 public constant MRV_MAX_REFERRAL_BPS = 1500;
    uint256 public constant MRV_MAX_SHARE_BPS = 8000;
    uint256 public constant MRV_DOMAIN_SALT = 0x7E3c1A9d5F2b8E0c4A6d2F9b1E5c7A3d0F8b4E6;
    uint256 public constant MRV_MAX_BURN_BATCH = 16;
    uint256 public constant MRV_MIN_JOIN_WEI = 0.01 ether;
    uint256 public constant MRV_MAX_JOIN_WEI = 500 ether;
    bytes32 public constant MRV_COLLECTIVA_DOMAIN = keccak256("MemeRevo.PonzuCollectiva.v1");

    address public immutable vault;
    address public immutable treasury;
    address public immutable burnPool;
    address public guardian;
    address public immutable referralHub;
    uint256 public immutable deployedBlock;
    bytes32 public immutable genesisHash;

    uint256 public minBurnAmountWei;
    uint256 public maxBurnPerTxWei;
    uint256 public referralBps;
    uint256 public infernoSequence;
    bool public collectivaPaused;

    struct TierConfig {
