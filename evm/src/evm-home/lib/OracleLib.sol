// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OracleLib
/// @notice Chainlink read that never reverts (stale, zero, missing or malformed feed all return
/// `ok = false`) and conversion of a token amount into USDC base units (6 decimals) via a token/USD feed.
library OracleLib {
    function read(address feed, uint32 maxAge) internal view returns (bool ok, uint256 answer, uint8 feedDecimals) {
        if (feed == address(0)) return (false, 0, 0);
        (bool s, bytes memory r) = feed.staticcall(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!s || r.length != 160) return (false, 0, 0);
        (, int256 a,, uint256 updatedAt,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
        if (a <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            return (false, 0, 0);
        }
        (s, r) = feed.staticcall(abi.encodeCall(IAggregatorV3.decimals, ()));
        if (!s || r.length != 32) return (false, 0, 0);
        uint256 d = abi.decode(r, (uint256));
        if (d > 36) return (false, 0, 0);
        return (true, uint256(a), uint8(d));
    }

    /// @dev value (USDC, 6 decimals) = amount * answer / 10^(tokenDecimals + feedDecimals - 6), rounded down.
    function toUsdc(uint256 amount, uint8 tokenDecimals, uint256 answer, uint8 feedDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 e = uint256(tokenDecimals) + feedDecimals;
        if (e >= 6) return Math.mulDiv(amount, answer, 10 ** (e - 6));
        return Math.mulDiv(amount, answer * 10 ** (6 - e), 1);
    }
}
