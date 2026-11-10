// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPolymarketGuardrail — Interface for Polymarket exposure monitoring
interface IPolymarketGuardrail {
    struct AgentGuardrail {
        address wallet;
        uint16 maxExposureBps;
        uint256 lastCheckTimestamp;
        uint256 lastExposureUsdc;
        uint256 cumulativePnl;
        int256 unrealizedPnl;
        uint32 totalPositions;
        uint32 winCount;
        uint32 lossCount;
        bool monitored;
    }

    event AgentMonitored(address indexed agent, address wallet, uint16 maxExposureBps);
    event ExposureChecked(address indexed agent, uint256 exposureUsdc, uint256 creditDrawn, uint16 exposureBps);
    event ExposureExceeded(address indexed agent, uint256 exposureUsdc, uint16 exposureBps, bool frozen);
    event PnlUpdated(address indexed agent, int256 pnlUsdc, uint32 wins, uint32 losses);
    event MarketRegistered(bytes32 conditionId);

    function monitorAgent(address agentOwner, address walletContract, uint16 maxExposureBps) external;
    function registerMarket(bytes32 conditionId) external;
    function trackCondition(address agentOwner, bytes32 conditionId) external;
    function setMaxExposure(address agentOwner, uint16 maxBps) external;

    function checkExposure(address agentOwner, uint256[] calldata positionIds)
        external returns (uint256 exposureUsdc, uint16 exposureBps, bool exceeded);

    function reportResolvedPosition(address agentOwner, int256 pnlUsdc, bool won) external;
    function updateUnrealizedPnl(address agentOwner, int256 unrealizedPnl) external;

    function getAgentStats(address agentOwner) external view returns (
        uint256 cumulativePnl,
        int256 unrealizedPnl,
        uint32 totalPositions,
        uint32 winCount,
        uint32 lossCount,
        uint16 winRateBps,
        uint256 lastExposureUsdc,
        uint16 maxExposureBps
    );

    function getPositionBalance(address walletAddress, uint256 positionId) external view returns (uint256);
    function isOverExposed(address agentOwner) external view returns (bool);
}
