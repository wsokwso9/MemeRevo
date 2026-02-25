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
        uint256 joinPriceWei;
        uint256 shareBps;
        bool active;
        uint256 memberCount;
        uint256 totalCollectedWei;
    }

    struct MemberRecord {
        uint8 tierId;
        uint256 joinedAtBlock;
        uint256 totalPaidWei;
        uint256 totalEarnedWei;
        address referrer;
    }

    struct InfernoLog {
        address token;
        address from;
        uint256 amountBurned;
        uint256 ethOut;
        uint256 atBlock;
    }

    struct TierSnapshot {
        uint8 tierId;
        uint256 memberCount;
        uint256 totalCollectedWei;
        uint256 atBlock;
        uint256 snapshotId;
    }

    struct BurnStats {
        uint256 totalBurnedWei;
        uint256 burnCount;
        uint256 totalEthOut;
    }

    struct CollectivaConfig {
        uint256 minBurnAmountWei;
        uint256 maxBurnPerTxWei;
        uint256 referralBps;
        uint8 activeTierCount;
        bool collectivaPaused;
        uint256 infernoSequence;
    }

    mapping(address => bool) public whitelistedMemeTokens;
    mapping(uint8 => TierConfig) public tierConfigs;
    mapping(address => MemberRecord) public members;
    mapping(address => bool) public hasJoined;
    mapping(address => uint256) public referralEarnings;
    mapping(address => uint256) public totalReferredWei;
    mapping(uint256 => InfernoLog) public infernoLogs;
    mapping(address => uint256) public totalBurnedByUser;
    mapping(address => mapping(address => uint256)) public userBurnPerToken;
    mapping(address => uint256) public userInfernoCount;
    mapping(uint8 => uint256) public tierPayoutCount;
    mapping(bytes32 => bool) private _usedNonces;
    address[] private _whitelistedTokenList;
    address[] private _memberList;
    uint8 public activeTierCount;
    uint256 public tierSnapshotSequence;
    uint256 public constant MRV_INFERNO_VAULT_BPS = 600;
    uint256 public constant MRV_INFERNO_TREASURY_BPS = 250;
    uint256 public constant MRV_NONCE_MAGIC = 0x3F8a2E6c1B9d4A7f0C5e8b2D6a9F1c4E7b0D3;
    mapping(uint256 => TierSnapshot) public tierSnapshots;
    uint256[] private _tierSnapshotIds;

    modifier whenCollectivaNotPaused() {
        if (collectivaPaused) revert MRV_CollectivaPaused();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert MRV_NotGuardian();
        _;
    }

    constructor() {
        vault = address(0x1F7b3D9e5A2c4E8b0D6f2A4c8E0b2D6f4A8c0E2);
        treasury = address(0x4A8c0E2b6D4f8A2c0E6b4D8f2A6c0E4b8D2f6A0);
        burnPool = address(0x7C2e6A0b4D8f2C6e0A4b8D2f6C0e4A8b2D6f0C2);
        guardian = address(0x9E3a5C7b1D9f3A5c7E1b9D3f5A7c1E9b3D5f7A1);
        referralHub = address(0x2B6d4F8a0C2e6A4b8D0f2C6a4E8b0D2f6A4c8E0);
        deployedBlock = block.number;
        genesisHash = keccak256(abi.encodePacked("MemeRevo", block.chainid, block.prevrandao, MRV_DOMAIN_SALT));
        minBurnAmountWei = 1000 * 1e18;
        maxBurnPerTxWei = 10_000_000 * 1e18;
        referralBps = 120;
        activeTierCount = 4;
        _initTiers();
    }

    function _initTiers() internal {
        tierConfigs[1] = TierConfig({ joinPriceWei: 0.05 ether, shareBps: 3500, active: true, memberCount: 0, totalCollectedWei: 0 });
        tierConfigs[2] = TierConfig({ joinPriceWei: 0.25 ether, shareBps: 4500, active: true, memberCount: 0, totalCollectedWei: 0 });
        tierConfigs[3] = TierConfig({ joinPriceWei: 1 ether, shareBps: 5500, active: true, memberCount: 0, totalCollectedWei: 0 });
        tierConfigs[4] = TierConfig({ joinPriceWei: 5 ether, shareBps: 7000, active: true, memberCount: 0, totalCollectedWei: 0 });
    }

    function setCollectivaPaused(bool paused) external onlyOwner {
        collectivaPaused = paused;
        emit CollectivaPaused(paused, block.number);
    }

    function setMinBurnAmountWei(uint256 amount) external onlyOwner {
        uint256 prev = minBurnAmountWei;
        minBurnAmountWei = amount;
        emit MinBurnAmountUpdated(prev, amount, block.number);
    }

    function setMaxBurnPerTxWei(uint256 amount) external onlyOwner {
        uint256 prev = maxBurnPerTxWei;
        maxBurnPerTxWei = amount;
        emit MaxBurnPerTxUpdated(prev, amount, block.number);
    }

    function setReferralBps(uint256 bps) external onlyOwner {
        if (bps > MRV_MAX_REFERRAL_BPS) revert MRV_InvalidReferralBps();
        uint256 prev = referralBps;
        referralBps = bps;
        emit ReferralBpsUpdated(prev, bps, block.number);
    }

    function setTierConfig(uint8 tierId, uint256 joinPriceWei, uint256 shareBps) external onlyOwner {
        if (tierId == 0 || tierId > MRV_MAX_TIERS) revert MRV_InvalidTier();
        if (shareBps > MRV_MAX_SHARE_BPS) revert MRV_InvalidShareBps();
        if (joinPriceWei < MRV_MIN_JOIN_WEI || joinPriceWei > MRV_MAX_JOIN_WEI) revert MRV_InvalidAmount();
        TierConfig storage t = tierConfigs[tierId];
        t.joinPriceWei = joinPriceWei;
        t.shareBps = shareBps;
        if (!t.active) t.active = true;
        emit TierConfigUpdated(tierId, joinPriceWei, shareBps, block.number);
    }

    function whitelistMemeToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert MRV_ZeroAddress();
        whitelistedMemeTokens[token] = allowed;
        bool found;
        for (uint256 i = 0; i < _whitelistedTokenList.length; i++) {
            if (_whitelistedTokenList[i] == token) { found = true; break; }
        }
        if (allowed && !found) _whitelistedTokenList.push(token);
        emit MemeTokenWhitelisted(token, allowed, block.number);
    }

    function rotateGuardian(address newGuardian_) external onlyOwner {
        if (newGuardian_ == address(0)) revert MRV_ZeroAddress();
        if (newGuardian_ == guardian) revert MRV_SameAddress();
        address prev = guardian;
        guardian = newGuardian_;
        emit GuardianRotated(prev, newGuardian_, block.number);
    }

    function infernoBurn(address token, uint256 amount) external nonReentrant whenCollectivaNotPaused returns (uint256 ethOut) {
        if (!whitelistedMemeTokens[token]) revert MRV_TokenNotWhitelisted();
        if (amount < minBurnAmountWei) revert MRV_AmountBelowMin();
        if (amount > maxBurnPerTxWei) revert MRV_AmountAboveMax();
        IERC20Meme t = IERC20Meme(token);
        uint256 bal = t.balanceOf(msg.sender);
        if (bal < amount) revert MRV_InsufficientPayment();
        uint256 ethBefore = address(this).balance;
        if (!t.transferFrom(msg.sender, address(this), amount)) revert MRV_TransferFailed();
        (bool burnOk,) = token.call(abi.encodeWithSelector(0x42966c68, amount));
        if (!burnOk) {
            (bool sendOk,) = token.call(abi.encodeWithSelector(0xa9059cbb, burnPool, amount));
            if (!sendOk) revert MRV_TransferFailed();
        }
        ethOut = address(this).balance - ethBefore;
        infernoSequence++;
        totalBurnedByUser[msg.sender] += amount;
        userBurnPerToken[msg.sender][token] += amount;
        userInfernoCount[msg.sender]++;
        infernoLogs[infernoSequence] = InfernoLog({ token: token, from: msg.sender, amountBurned: amount, ethOut: ethOut, atBlock: block.number });
        emit TokenInferno(token, msg.sender, amount, ethOut, block.number);
        if (ethOut > 0) {
            uint256 toVault = (ethOut * MRV_INFERNO_VAULT_BPS) / MRV_BPS_BASE;
            uint256 toTreasury = (ethOut * MRV_INFERNO_TREASURY_BPS) / MRV_BPS_BASE;
            if (toVault > 0) _safeSend(vault, toVault);
            if (toTreasury > 0) _safeSend(treasury, toTreasury);
        }
        return ethOut;
    }

    function infernoBurnBatch(address[] calldata tokens, uint256[] calldata amounts) external nonReentrant whenCollectivaNotPaused returns (uint256 totalEthOut) {
        if (tokens.length != amounts.length) revert MRV_ArrayLengthMismatch();
        if (tokens.length > MRV_MAX_BURN_BATCH) revert MRV_BatchTooLarge();
        uint256 totalBurned = 0;
        uint256 ethBefore = address(this).balance;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (!whitelistedMemeTokens[token]) continue;
            if (amount < minBurnAmountWei) continue;
            if (amount > maxBurnPerTxWei) continue;
            IERC20Meme t = IERC20Meme(token);
            if (t.balanceOf(msg.sender) < amount) continue;
            if (!t.transferFrom(msg.sender, address(this), amount)) continue;
            (bool burnOk,) = token.call(abi.encodeWithSelector(0x42966c68, amount));
            if (!burnOk) {
                (bool sendOk,) = token.call(abi.encodeWithSelector(0xa9059cbb, burnPool, amount));
                if (!sendOk) continue;
            }
            totalBurned += amount;
        }
        totalEthOut = address(this).balance - ethBefore;
        infernoSequence++;
        if (totalBurned > 0) {
            totalBurnedByUser[msg.sender] += totalBurned;
            userInfernoCount[msg.sender]++;
        }
        emit InfernoBatch(msg.sender, tokens.length, totalBurned, block.number);
        if (totalEthOut > 0) {
            uint256 toVault = (totalEthOut * MRV_INFERNO_VAULT_BPS) / MRV_BPS_BASE;
            uint256 toTreasury = (totalEthOut * MRV_INFERNO_TREASURY_BPS) / MRV_BPS_BASE;
            if (toVault > 0) _safeSend(vault, toVault);
            if (toTreasury > 0) _safeSend(treasury, toTreasury);
        }
        return totalEthOut;
    }

    function joinCollectiva(uint8 tierId, address referrer) external payable nonReentrant whenCollectivaNotPaused {
        if (tierId == 0 || tierId > activeTierCount) revert MRV_InvalidTier();
        TierConfig storage t = tierConfigs[tierId];
        if (!t.active) revert MRV_InvalidTier();
        if (msg.value < t.joinPriceWei) revert MRV_InsufficientPayment();
        if (hasJoined[msg.sender]) revert MRV_AlreadyMember();
        hasJoined[msg.sender] = true;
        members[msg.sender] = MemberRecord({
            tierId: tierId,
            joinedAtBlock: block.number,
            totalPaidWei: msg.value,
            totalEarnedWei: 0,
            referrer: referrer != address(0) ? referrer : referralHub
        });
        t.memberCount++;
        t.totalCollectedWei += msg.value;
        _memberList.push(msg.sender);
        uint256 refBps = (referrer != address(0) && referrer != msg.sender) ? referralBps : 0;
        uint256 refAmount = (msg.value * refBps) / MRV_BPS_BASE;
        uint256 toMembers = (msg.value * t.shareBps) / MRV_BPS_BASE;
        uint256 toVault = msg.value - refAmount - toMembers;
        if (refAmount > 0 && referrer != address(0)) {
            referralEarnings[referrer] += refAmount;
            totalReferredWei[referrer] += msg.value;
            _safeSend(referrer, refAmount);
            emit ReferralCredited(referrer, msg.sender, refAmount, block.number);
        }
        if (toMembers > 0) _distributeToTier(tierId, toMembers);
        if (toVault > 0) _safeSend(vault, toVault);
        tierSnapshotSequence++;
        tierSnapshots[tierSnapshotSequence] = TierSnapshot({
            tierId: tierId,
            memberCount: tierConfigs[tierId].memberCount,
            totalCollectedWei: tierConfigs[tierId].totalCollectedWei,
            atBlock: block.number,
            snapshotId: tierSnapshotSequence
        });
        _tierSnapshotIds.push(tierSnapshotSequence);
        emit MemberJoined(msg.sender, tierId, referrer, block.number);
        emit TierAscended(msg.sender, tierId, msg.value, block.number);
    }

    function _distributeToTier(uint8 tierId, uint256 amountWei) internal {
        TierConfig storage t = tierConfigs[tierId];
        if (t.memberCount == 0) return;
        uint256 perMember = amountWei / t.memberCount;
        if (perMember == 0) return;
        uint256 distributed = 0;
        for (uint256 i = 0; i < _memberList.length && distributed < amountWei; i++) {
            address m = _memberList[i];
            if (members[m].tierId == tierId) {
                uint256 pay = perMember;
                if (distributed + pay > amountWei) pay = amountWei - distributed;
                members[m].totalEarnedWei += pay;
                _safeSend(m, pay);
                distributed += pay;
                tierPayoutCount[tierId]++;
                emit PayoutDistributed(m, tierId, pay, block.number);
            }
        }
    }

    function harvestVault(uint256 amountWei) external onlyGuardian nonReentrant {
        if (amountWei == 0) revert MRV_ZeroAmount();
        if (address(this).balance < amountWei) revert MRV_NoBalance();
        _safeSend(vault, amountWei);
        emit VaultHarvest(vault, amountWei, block.number);
    }

    function harvestTreasury(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert MRV_ZeroAmount();
        if (address(this).balance < amountWei) revert MRV_NoBalance();
        _safeSend(treasury, amountWei);
        emit TreasuryHarvest(treasury, amountWei, block.number);
    }

    function _safeSend(address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert MRV_TransferFailed();
    }

    function getMemberInfo(address account) external view returns (
        uint8 tierId,
        uint256 joinedAtBlock,
        uint256 totalPaidWei,
        uint256 totalEarnedWei,
        address referrer
    ) {
        MemberRecord storage m = members[account];
        return (m.tierId, m.joinedAtBlock, m.totalPaidWei, m.totalEarnedWei, m.referrer);
    }

    function getTierInfo(uint8 tierId) external view returns (
        uint256 joinPriceWei,
        uint256 shareBps,
        bool active,
        uint256 memberCount,
        uint256 totalCollectedWei
    ) {
        TierConfig storage t = tierConfigs[tierId];
        return (t.joinPriceWei, t.shareBps, t.active, t.memberCount, t.totalCollectedWei);
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return _whitelistedTokenList;
    }

    function getMemberCount() external view returns (uint256) {
        return _memberList.length;
    }

    function getInfernoLog(uint256 logId) external view returns (address token, address from, uint256 amountBurned, uint256 ethOut, uint256 atBlock) {
        InfernoLog storage l = infernoLogs[logId];
        return (l.token, l.from, l.amountBurned, l.ethOut, l.atBlock);
    }

    receive() external payable {}

    function withdrawStuckToken(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) revert MRV_ZeroAddress();
        if (amount == 0) revert MRV_ZeroAmount();
        IERC20Meme t = IERC20Meme(token);
        uint256 bal = t.balanceOf(address(this));
        if (bal < amount) revert MRV_InsufficientPayment();
        (bool ok,) = token.call(abi.encodeWithSelector(0xa9059cbb, treasury, amount));
        if (!ok) revert MRV_TransferFailed();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getConfig() external view returns (
        uint256 minBurn_,
        uint256 maxBurn_,
        uint256 referralBps_,
        uint8 activeTierCount_,
        bool paused_
    ) {
        return (minBurnAmountWei, maxBurnPerTxWei, referralBps, activeTierCount, collectivaPaused);
    }

    function getImmutableAddresses() external view returns (
        address vault_,
        address treasury_,
        address burnPool_,
        address guardian_,
        address referralHub_
    ) {
        return (vault, treasury, burnPool, guardian, referralHub);
    }

    function setActiveTierCount(uint8 count) external onlyOwner {
        if (count == 0 || count > MRV_MAX_TIERS) revert MRV_InvalidTier();
        activeTierCount = count;
    }

    function emergencyPauseByGuardian() external onlyGuardian {
        collectivaPaused = true;
        emit CollectivaPaused(true, block.number);
    }

    function computeMemberShare(address member, uint8 tierId) external view returns (uint256 shareBps) {
        TierConfig storage t = tierConfigs[tierId];
        if (t.memberCount == 0) return 0;
        return t.shareBps / t.memberCount;
    }

    function isWhitelisted(address token) external view returns (bool) {
        return whitelistedMemeTokens[token];
    }

    function totalInfernoSequence() external view returns (uint256) {
        return infernoSequence;
    }

    function memberAt(uint256 index) external view returns (address) {
        if (index >= _memberList.length) revert MRV_InvalidTier();
        return _memberList[index];
    }

    function getGenesisHash() external view returns (bytes32) {
        return genesisHash;
    }

    function getDeployedBlock() external view returns (uint256) {
        return deployedBlock;
    }

    function tierActive(uint8 tierId) external view returns (bool) {
        return tierId <= MRV_MAX_TIERS && tierConfigs[tierId].active;
    }

    function referralEarningsOf(address account) external view returns (uint256) {
        return referralEarnings[account];
    }

    function totalReferredWeiOf(address account) external view returns (uint256) {
        return totalReferredWei[account];
    }

    function collectivaDomain() external pure returns (bytes32) {
        return MRV_COLLECTIVA_DOMAIN;
    }

    function domainSalt() external pure returns (uint256) {
        return MRV_DOMAIN_SALT;
    }

    function bpsBase() external pure returns (uint256) {
        return MRV_BPS_BASE;
    }

    function maxTiers() external pure returns (uint256) {
        return MRV_MAX_TIERS;
    }

    function maxReferralBps() external pure returns (uint256) {
        return MRV_MAX_REFERRAL_BPS;
    }

    function maxShareBps() external pure returns (uint256) {
        return MRV_MAX_SHARE_BPS;
    }

    function maxBurnBatch() external pure returns (uint256) {
        return MRV_MAX_BURN_BATCH;
    }

    function minJoinWei() external pure returns (uint256) {
        return MRV_MIN_JOIN_WEI;
    }

    function maxJoinWei() external pure returns (uint256) {
        return MRV_MAX_JOIN_WEI;
    }

    function getBurnStats(address account) external view returns (uint256 totalBurnedWei, uint256 burnCount, uint256 totalEthOut) {
        totalBurnedWei = totalBurnedByUser[account];
        burnCount = userInfernoCount[account];
        totalEthOut = 0;
        return (totalBurnedWei, burnCount, totalEthOut);
    }

    function getBurnStatsForToken(address account, address token) external view returns (uint256) {
        return userBurnPerToken[account][token];
    }

    function getCollectivaConfigStruct() external view returns (CollectivaConfig memory c) {
        c.minBurnAmountWei = minBurnAmountWei;
        c.maxBurnPerTxWei = maxBurnPerTxWei;
        c.referralBps = referralBps;
        c.activeTierCount = activeTierCount;
        c.collectivaPaused = collectivaPaused;
        c.infernoSequence = infernoSequence;
        return c;
    }

    function getTierSnapshotById(uint256 snapshotId) external view returns (TierSnapshot memory) {
        return tierSnapshots[snapshotId];
    }

    function getTierSnapshotCount() external view returns (uint256) {
        return _tierSnapshotIds.length;
    }

    function getTierSnapshotIdAt(uint256 index) external view returns (uint256) {
        if (index >= _tierSnapshotIds.length) revert MRV_InvalidTier();
        return _tierSnapshotIds[index];
    }

    function getTierPayoutCount(uint8 tierId) external view returns (uint256) {
        return tierPayoutCount[tierId];
    }

    function batchWhitelistMemeTokens(address[] calldata tokens, bool allowed) external onlyOwner {
        if (tokens.length > MRV_MAX_BURN_BATCH * 2) revert MRV_BatchTooLarge();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            whitelistedMemeTokens[token] = allowed;
            bool found;
            for (uint256 j = 0; j < _whitelistedTokenList.length; j++) {
                if (_whitelistedTokenList[j] == token) { found = true; break; }
            }
            if (allowed && !found) _whitelistedTokenList.push(token);
            emit MemeTokenWhitelisted(token, allowed, block.number);
        }
    }

    function infernoVaultBps() external pure returns (uint256) {
        return MRV_INFERNO_VAULT_BPS;
    }

    function infernoTreasuryBps() external pure returns (uint256) {
        return MRV_INFERNO_TREASURY_BPS;
    }

    function nonceMagic() external pure returns (uint256) {
        return MRV_NONCE_MAGIC;
    }

    function usedNonce(bytes32 nonce) external view returns (bool) {
        return _usedNonces[nonce];
    }

    function markNonceUsed(bytes32 nonce) external onlyGuardian {
        if (_usedNonces[nonce]) revert MRV_InvalidAmount();
        _usedNonces[nonce] = true;
        emit NonceMarkedUsed(nonce, msg.sender, block.number);
    }

    function _tryBurnToken(address token, uint256 amount) internal returns (bool) {
        (bool burnOk,) = token.call(abi.encodeWithSelector(0x42966c68, amount));
        return burnOk;
    }

    function _trySendTokenToBurnPool(address token, uint256 amount) internal returns (bool) {
        (bool sendOk,) = token.call(abi.encodeWithSelector(0xa9059cbb, burnPool, amount));
        return sendOk;
    }

    function _computeVaultShare(uint256 ethAmount) internal pure returns (uint256) {
        return (ethAmount * MRV_INFERNO_VAULT_BPS) / MRV_BPS_BASE;
    }

    function _computeTreasuryShare(uint256 ethAmount) internal pure returns (uint256) {
        return (ethAmount * MRV_INFERNO_TREASURY_BPS) / MRV_BPS_BASE;
    }

    function _validateTierId(uint8 tierId) internal view returns (bool) {
        return tierId != 0 && tierId <= activeTierCount && tierConfigs[tierId].active;
    }

    function _validateBurnAmount(uint256 amount) internal view returns (bool) {
        return amount >= minBurnAmountWei && amount <= maxBurnPerTxWei;
    }

    function _recordBurnStats(address user, address token, uint256 amount) internal {
        totalBurnedByUser[user] += amount;
        userBurnPerToken[user][token] += amount;
        userInfernoCount[user]++;
        emit BurnStatsUpdated(user, token, amount, block.number);
    }

    function _recordTierSnapshot(uint8 tierId) internal {
        tierSnapshotSequence++;
        tierSnapshots[tierSnapshotSequence] = TierSnapshot({
            tierId: tierId,
            memberCount: tierConfigs[tierId].memberCount,
            totalCollectedWei: tierConfigs[tierId].totalCollectedWei,
            atBlock: block.number,
            snapshotId: tierSnapshotSequence
        });
        _tierSnapshotIds.push(tierSnapshotSequence);
        emit SnapshotRecorded(tierSnapshotSequence, tierId, tierConfigs[tierId].memberCount, block.number);
    }

    function getInfernoVaultShare(uint256 ethAmount) external pure returns (uint256) {
        return _computeVaultShare(ethAmount);
    }

    function getInfernoTreasuryShare(uint256 ethAmount) external pure returns (uint256) {
        return _computeTreasuryShare(ethAmount);
    }

    function validateTierForJoin(uint8 tierId) external view returns (bool) {
        return _validateTierId(tierId);
    }

    function validateBurnAmount(uint256 amount) external view returns (bool) {
        return _validateBurnAmount(amount);
    }

    function getTotalBurnedByUser(address account) external view returns (uint256) {
        return totalBurnedByUser[account];
    }

    function getUserInfernoCount(address account) external view returns (uint256) {
        return userInfernoCount[account];
    }

    function getReferrerEarnings(address account) external view returns (uint256) {
        return referralEarnings[account];
    }

    function getTotalReferredWei(address account) external view returns (uint256) {
        return totalReferredWei[account];
    }

    function getAllTierIds() external view returns (uint8[] memory ids) {
        ids = new uint8[](activeTierCount);
        for (uint8 i = 1; i <= activeTierCount; i++) ids[i - 1] = i;
        return ids;
    }

    function getTierIdsActive() external view returns (uint8[] memory ids) {
        uint256 n;
        for (uint8 i = 1; i <= MRV_MAX_TIERS; i++) if (tierConfigs[i].active) n++;
        ids = new uint8[](n);
        uint256 j;
        for (uint8 i = 1; i <= MRV_MAX_TIERS; i++) {
            if (tierConfigs[i].active) { ids[j] = i; j++; }
        }
        return ids;
    }

    function getJoinPriceForTier(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].joinPriceWei;
    }

    function getShareBpsForTier(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].shareBps;
    }

    function getMemberCountForTier(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].memberCount;
    }

    function getTotalCollectedForTier(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].totalCollectedWei;
    }

    function isTierActive(uint8 tierId) external view returns (bool) {
        return tierId <= MRV_MAX_TIERS && tierConfigs[tierId].active;
    }

    function getGenesisBlock() external view returns (uint256) {
        return deployedBlock;
    }

    function getDomainSalt() external pure returns (uint256) {
        return MRV_DOMAIN_SALT;
    }

    function getCollectivaDomainHash() external pure returns (bytes32) {
        return MRV_COLLECTIVA_DOMAIN;
    }

    function getBpsBase() external pure returns (uint256) {
        return MRV_BPS_BASE;
    }

    function getMaxTiers() external pure returns (uint256) {
        return MRV_MAX_TIERS;
    }

    function getMaxReferralBps() external pure returns (uint256) {
        return MRV_MAX_REFERRAL_BPS;
    }

    function getMaxShareBps() external pure returns (uint256) {
        return MRV_MAX_SHARE_BPS;
    }

    function getMaxBurnBatchSize() external pure returns (uint256) {
        return MRV_MAX_BURN_BATCH;
    }

    function getMinJoinWeiLimit() external pure returns (uint256) {
        return MRV_MIN_JOIN_WEI;
    }

    function getMaxJoinWeiLimit() external pure returns (uint256) {
        return MRV_MAX_JOIN_WEI;
    }

    function getVaultAddress() external view returns (address) {
        return vault;
    }

    function getTreasuryAddress() external view returns (address) {
        return treasury;
    }

    function getBurnPoolAddress() external view returns (address) {
        return burnPool;
    }

    function getGuardianAddress() external view returns (address) {
        return guardian;
    }

    function getReferralHubAddress() external view returns (address) {
        return referralHub;
    }

    function getInfernoSequence() external view returns (uint256) {
        return infernoSequence;
    }

    function getSnapshotSequence() external view returns (uint256) {
        return tierSnapshotSequence;
    }

    function getCollectivaPaused() external view returns (bool) {
        return collectivaPaused;
    }

    function getMinBurnAmount() external view returns (uint256) {
        return minBurnAmountWei;
    }

    function getMaxBurnPerTx() external view returns (uint256) {
        return maxBurnPerTxWei;
    }

    function getReferralBps() external view returns (uint256) {
        return referralBps;
    }

    function getActiveTierCount() external view returns (uint8) {
        return activeTierCount;
    }

    function membersLength() external view returns (uint256) {
        return _memberList.length;
    }

    function snapshotIdsLength() external view returns (uint256) {
        return _tierSnapshotIds.length;
    }

    function computeJoinCost(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].joinPriceWei;
    }

    function computeReferralCut(uint256 weiAmount) external view returns (uint256) {
        return (weiAmount * referralBps) / MRV_BPS_BASE;
    }

    function computeMemberCut(uint256 weiAmount, uint8 tierId) external view returns (uint256) {
        return (weiAmount * tierConfigs[tierId].shareBps) / MRV_BPS_BASE;
    }

    function computeVaultCut(uint256 weiAmount, uint8 tierId, bool hasReferrer) external view returns (uint256) {
        uint256 ref = hasReferrer ? (weiAmount * referralBps) / MRV_BPS_BASE : 0;
        uint256 toMembers = (weiAmount * tierConfigs[tierId].shareBps) / MRV_BPS_BASE;
        return weiAmount - ref - toMembers;
    }

    function checkWhitelist(address token) external view returns (bool) {
        return whitelistedMemeTokens[token];
    }

    function checkMember(address account) external view returns (bool) {
        return hasJoined[account];
    }

    function checkTierActive(uint8 tierId) external view returns (bool) {
        return tierId != 0 && tierId <= MRV_MAX_TIERS && tierConfigs[tierId].active;
    }

    function fetchMemberTier(address account) external view returns (uint8) {
        return members[account].tierId;
    }

    function fetchMemberReferrer(address account) external view returns (address) {
        return members[account].referrer;
    }

    function fetchMemberPaid(address account) external view returns (uint256) {
        return members[account].totalPaidWei;
    }

    function fetchMemberEarned(address account) external view returns (uint256) {
        return members[account].totalEarnedWei;
    }

    function fetchMemberJoinedBlock(address account) external view returns (uint256) {
        return members[account].joinedAtBlock;
    }

    function fetchInfernoLogToken(uint256 logId) external view returns (address) {
        return infernoLogs[logId].token;
    }

    function fetchInfernoLogFrom(uint256 logId) external view returns (address) {
        return infernoLogs[logId].from;
    }

    function fetchInfernoLogAmount(uint256 logId) external view returns (uint256) {
        return infernoLogs[logId].amountBurned;
    }

    function fetchInfernoLogEthOut(uint256 logId) external view returns (uint256) {
        return infernoLogs[logId].ethOut;
    }

    function fetchInfernoLogBlock(uint256 logId) external view returns (uint256) {
        return infernoLogs[logId].atBlock;
    }

    function deactivateTierEvent(uint8 tierId) external onlyOwner {
        if (tierId == 0 || tierId > MRV_MAX_TIERS) revert MRV_InvalidTier();
        tierConfigs[tierId].active = false;
        emit TierDeactivated(tierId, block.number);
        emit TierConfigUpdated(tierId, tierConfigs[tierId].joinPriceWei, tierConfigs[tierId].shareBps, block.number);
    }

    function activateTierEvent(uint8 tierId) external onlyOwner {
        if (tierId == 0 || tierId > MRV_MAX_TIERS) revert MRV_InvalidTier();
        tierConfigs[tierId].active = true;
        emit TierActivated(tierId, block.number);
        emit TierConfigUpdated(tierId, tierConfigs[tierId].joinPriceWei, tierConfigs[tierId].shareBps, block.number);
    }

    function emitMinJoinWeiEnforced() external onlyOwner {
        emit MinJoinWeiEnforced(MRV_MIN_JOIN_WEI, block.number);
    }

    function emitMaxJoinWeiEnforced() external onlyOwner {
        emit MaxJoinWeiEnforced(MRV_MAX_JOIN_WEI, block.number);
    }

    function emitConfigFrozen() external onlyOwner {
        emit ConfigFrozen(block.number);
    }

    function totalSupplyOfMembers() external view returns (uint256) {
        return _memberList.length;
    }

    function totalSupplyOfSnapshots() external view returns (uint256) {
        return _tierSnapshotIds.length;
    }

    function totalSupplyOfWhitelistedTokens() external view returns (uint256) {
        return _whitelistedTokenList.length;
    }

    function getTierName(uint8 tierId) external pure returns (string memory) {
        if (tierId == 1) return "Bronze";
        if (tierId == 2) return "Silver";
        if (tierId == 3) return "Gold";
        if (tierId == 4) return "Diamond";
        if (tierId == 5) return "Platinum";
        if (tierId == 6) return "Obsidian";
        if (tierId == 7) return "Void";
        if (tierId == 8) return "Apex";
        return "Unknown";
    }

    function getTierJoinPriceWei(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].joinPriceWei;
    }

    function getTierShareBpsWei(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].shareBps;
    }

    function getTierActiveFlag(uint8 tierId) external view returns (bool) {
        return tierConfigs[tierId].active;
    }

    function getTierMemberCountWei(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].memberCount;
    }

    function getTierTotalCollectedWei(uint8 tierId) external view returns (uint256) {
        return tierConfigs[tierId].totalCollectedWei;
    }

    function getMemberTierId(address account) external view returns (uint8) {
        return members[account].tierId;
    }

    function getMemberJoinedBlock(address account) external view returns (uint256) {
        return members[account].joinedAtBlock;
    }

    function getMemberTotalPaidWei(address account) external view returns (uint256) {
        return members[account].totalPaidWei;
    }

    function getMemberTotalEarnedWei(address account) external view returns (uint256) {
        return members[account].totalEarnedWei;
    }

    function getMemberReferrerAddress(address account) external view returns (address) {
        return members[account].referrer;
    }

    function getInfernoLogBySequence(uint256 seq) external view returns (InfernoLog memory) {
        return infernoLogs[seq];
    }

    function getSnapshotBySequence(uint256 seq) external view returns (TierSnapshot memory) {
        return tierSnapshots[seq];
    }

    function getPayoutCountForTier(uint8 tierId) external view returns (uint256) {
        return tierPayoutCount[tierId];
    }

    function getBurnedByUserTotal(address account) external view returns (uint256) {
        return totalBurnedByUser[account];
    }

    function getBurnedByUserForToken(address account, address token) external view returns (uint256) {
        return userBurnPerToken[account][token];
    }

    function getInfernoCountForUser(address account) external view returns (uint256) {
        return userInfernoCount[account];
    }

    function getMemberListSlice(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 len = _memberList.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _memberList[offset + i];
        return out;
    }

    function getWhitelistedTokenCount() external view returns (uint256) {
        return _whitelistedTokenList.length;
    }

    function getTierConfigStruct(uint8 tierId) external view returns (TierConfig memory) {
        return tierConfigs[tierId];
    }

    function getMemberRecordStruct(address account) external view returns (MemberRecord memory) {
        return members[account];
    }

    function getInfernoLogStruct(uint256 logId) external view returns (InfernoLog memory) {
        return infernoLogs[logId];
    }

