// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WaterfallLib — Sequential waterfall distribution math
/// @notice Port of MerchantVault::distribute_waterfall() from Solana vault.rs
/// @dev Pure library. Order: Senior → Pools → Community. All checked math.
library WaterfallLib {
    struct Distribution {
        uint256 seniorPayment;
        uint256 poolPayment;
        uint256 communityPayment;
    }

    /// @notice Distribute a repayment amount through the waterfall
    /// @param seniorOwed Remaining amount owed to senior tranche
    /// @param poolOwed Remaining amount owed to liquidity pool tranche
    /// @param amount Total repayment amount to distribute
    /// @return dist The distribution across tranches
    function distribute(
        uint256 seniorOwed,
        uint256 poolOwed,
        uint256 amount
    ) internal pure returns (Distribution memory dist) {
        // Senior tranche paid first
        dist.seniorPayment = amount > seniorOwed ? seniorOwed : amount;
        uint256 remaining = amount - dist.seniorPayment;

        // Liquidity pools paid second
        dist.poolPayment = remaining > poolOwed ? poolOwed : remaining;
        remaining = remaining - dist.poolPayment;

        // Community investors receive whatever remains
        dist.communityPayment = remaining;
    }
}
