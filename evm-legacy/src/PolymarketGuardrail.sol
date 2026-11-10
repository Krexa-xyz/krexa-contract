// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IPolymarketGuardrail} from "./interfaces/IPolymarketGuardrail.sol";
import {IAgentWallet} from "./interfaces/IAgentWallet.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title PolymarketGuardrail — On-chain credit risk monitoring for Polymarket
/// @notice Reads agent CTF positions on Polygon, enforces exposure limits relative
///         to Krexa credit lines, and feeds PnL data to KrexitScore.
contract PolymarketGuardrail is IPolymarketGuardrail {

    // ── Constants ─────────────────────────────────────────────────────

    uint16 public constant BPS = 10_000;
    uint16 public constant DEFAULT_MAX_EXPOSURE_BPS = 3_000;  // 30% of credit
    uint16 public constant AUTO_FREEZE_EXPOSURE_BPS = 5_000;  // 50% → auto-freeze
    uint256 public constant MIN_CHECK_INTERVAL = 60;          // 1 minute

    // ── Immutables ────────────────────────────────────────────────────

    IERC1155 public immutable conditionalTokens;

    // ── State ─────────────────────────────────────────────────────────

    address public admin;
    address public oracle;

    mapping(address => AgentGuardrail) private _guardrails;
    mapping(address => bytes32[]) private _trackedConditions;
    mapping(bytes32 => bool) public knownMarkets;

    // ── Modifiers ─────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyAdminOrOracle() {
        if (msg.sender != admin && msg.sender != oracle) revert Errors.OnlyAdminOrOracle();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────

    constructor(address _conditionalTokens, address _admin, address _oracle) {
        if (_conditionalTokens == address(0) || _admin == address(0) || _oracle == address(0))
            revert Errors.ZeroAddress();
        conditionalTokens = IERC1155(_conditionalTokens);
        admin = _admin;
        oracle = _oracle;
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN: Setup
    // ═══════════════════════════════════════════════════════════════════

    function monitorAgent(
        address agentOwner,
        address walletContract,
        uint16 maxExposureBps
    ) external onlyAdminOrOracle {
        if (walletContract == address(0)) revert Errors.ZeroAddress();
        if (maxExposureBps == 0) maxExposureBps = DEFAULT_MAX_EXPOSURE_BPS;

        _guardrails[agentOwner] = AgentGuardrail({
            wallet: walletContract,
            maxExposureBps: maxExposureBps,
            lastCheckTimestamp: 0,
            lastExposureUsdc: 0,
            cumulativePnl: 0,
            unrealizedPnl: 0,
            totalPositions: 0,
            winCount: 0,
            lossCount: 0,
            monitored: true
        });

        emit AgentMonitored(agentOwner, walletContract, maxExposureBps);
    }

    function registerMarket(bytes32 conditionId) external onlyAdminOrOracle {
        knownMarkets[conditionId] = true;
        emit MarketRegistered(conditionId);
    }

    function trackCondition(address agentOwner, bytes32 conditionId) external onlyAdminOrOracle {
        if (!_guardrails[agentOwner].monitored) revert Errors.AgentNotActive();
        _trackedConditions[agentOwner].push(conditionId);
    }

    function setMaxExposure(address agentOwner, uint16 maxBps) external onlyAdminOrOracle {
        if (!_guardrails[agentOwner].monitored) revert Errors.AgentNotActive();
        _guardrails[agentOwner].maxExposureBps = maxBps;
    }

    function setOracle(address newOracle) external onlyAdmin {
        if (newOracle == address(0)) revert Errors.ZeroAddress();
        oracle = newOracle;
    }

    // ═══════════════════════════════════════════════════════════════════
    // EXPOSURE CHECKING (permissionless)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Check an agent's total Polymarket exposure against their credit line.
    ///         Anyone can call this — keepers, oracle, or the agent themselves.
    function checkExposure(
        address agentOwner,
        uint256[] calldata positionIds
    ) external returns (uint256 exposureUsdc, uint16 exposureBps, bool exceeded) {
        AgentGuardrail storage g = _guardrails[agentOwner];
        if (!g.monitored) revert Errors.AgentNotActive();
        if (block.timestamp < g.lastCheckTimestamp + MIN_CHECK_INTERVAL)
            revert Errors.RateLimitExceeded();

        IAgentWallet wallet = IAgentWallet(g.wallet);
        uint256 creditDrawn = wallet.creditDrawn();

        // Sum all CTF position balances for this agent's wallet
        // Each CTF share = 1 USDC collateral (Polymarket USDC-denominated)
        exposureUsdc = 0;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 balance = conditionalTokens.balanceOf(g.wallet, positionIds[i]);
            exposureUsdc += balance;
        }

        // Calculate exposure as BPS of credit drawn
        if (creditDrawn > 0) {
            exposureBps = uint16((exposureUsdc * BPS) / creditDrawn);
        } else {
            exposureBps = 0;
        }

        // Update state
        g.lastCheckTimestamp = block.timestamp;
        g.lastExposureUsdc = exposureUsdc;

        emit ExposureChecked(agentOwner, exposureUsdc, creditDrawn, exposureBps);

        // Check guardrail
        exceeded = exposureBps > g.maxExposureBps;

        if (exceeded) {
            emit ExposureExceeded(agentOwner, exposureUsdc, exposureBps, false);

            // Auto-freeze if above hard limit
            if (exposureBps > AUTO_FREEZE_EXPOSURE_BPS && !wallet.frozen()) {
                try wallet.freeze() {
                    emit ExposureExceeded(agentOwner, exposureUsdc, exposureBps, true);
                } catch {}
            }
        }

        return (exposureUsdc, exposureBps, exceeded);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PNL TRACKING (oracle-fed)
    // ═══════════════════════════════════════════════════════════════════

    function reportResolvedPosition(
        address agentOwner,
        int256 pnlUsdc,
        bool won
    ) external onlyAdminOrOracle {
        AgentGuardrail storage g = _guardrails[agentOwner];
        if (!g.monitored) revert Errors.AgentNotActive();

        g.totalPositions++;
        if (won) {
            g.winCount++;
        } else {
            g.lossCount++;
        }

        if (pnlUsdc >= 0) {
            g.cumulativePnl += uint256(pnlUsdc);
        } else {
            uint256 loss = uint256(-pnlUsdc);
            if (loss > g.cumulativePnl) {
                g.cumulativePnl = 0;
            } else {
                g.cumulativePnl -= loss;
            }
        }

        emit PnlUpdated(agentOwner, pnlUsdc, g.winCount, g.lossCount);
    }

    function updateUnrealizedPnl(
        address agentOwner,
        int256 unrealizedPnl
    ) external onlyAdminOrOracle {
        _guardrails[agentOwner].unrealizedPnl = unrealizedPnl;
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function getAgentStats(address agentOwner) external view returns (
        uint256 cumulativePnl,
        int256 unrealizedPnl,
        uint32 totalPositions,
        uint32 winCount,
        uint32 lossCount,
        uint16 winRateBps,
        uint256 lastExposureUsdc,
        uint16 maxExposureBps
    ) {
        AgentGuardrail storage g = _guardrails[agentOwner];
        winRateBps = g.totalPositions > 0
            ? uint16((uint256(g.winCount) * BPS) / uint256(g.totalPositions))
            : 0;
        return (
            g.cumulativePnl,
            g.unrealizedPnl,
            g.totalPositions,
            g.winCount,
            g.lossCount,
            winRateBps,
            g.lastExposureUsdc,
            g.maxExposureBps
        );
    }

    function guardrails(address agentOwner) external view returns (AgentGuardrail memory) {
        return _guardrails[agentOwner];
    }

    function getTrackedConditions(address agentOwner) external view returns (bytes32[] memory) {
        return _trackedConditions[agentOwner];
    }

    function getPositionBalance(
        address walletAddress,
        uint256 positionId
    ) external view returns (uint256) {
        return conditionalTokens.balanceOf(walletAddress, positionId);
    }

    function isOverExposed(address agentOwner) external view returns (bool) {
        AgentGuardrail storage g = _guardrails[agentOwner];
        if (!g.monitored) return false;
        IAgentWallet wallet = IAgentWallet(g.wallet);
        uint256 creditDrawn = wallet.creditDrawn();
        if (creditDrawn == 0) return false;
        uint16 bps = uint16((g.lastExposureUsdc * BPS) / creditDrawn);
        return bps > g.maxExposureBps;
    }
}
