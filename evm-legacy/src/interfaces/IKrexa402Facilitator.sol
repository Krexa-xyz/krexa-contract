// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymentRouter} from "./IPaymentRouter.sol";

interface IKrexa402Facilitator {
    struct Resource {
        address owner;          // merchant who registered the resource
        uint256 pricePerCall;   // price in USDC (6 decimals)
        bool active;
    }

    event ResourceRegistered(bytes32 indexed resourceHash, address indexed owner, uint256 pricePerCall);
    event ResourceUpdated(bytes32 indexed resourceHash, uint256 newPrice);
    event ResourceDeactivated(bytes32 indexed resourceHash);
    event X402PaymentExecuted(
        bytes32 indexed resourceHash,
        address indexed payer,
        address indexed merchant,
        uint256 amount,
        uint256 facilitatorFee,
        bytes32 paymentId
    );
    event FacilitatorFeeUpdated(uint16 oldBps, uint16 newBps);

    function registerResource(bytes32 resourceHash, uint256 pricePerCall) external;
    function updateResourcePrice(bytes32 resourceHash, uint256 newPrice) external;
    function deactivateResource(bytes32 resourceHash) external;
    function executeX402Payment(
        bytes32 resourceHash,
        IPaymentRouter.X402Payment calldata payment,
        bytes calldata signature
    ) external;
    function getResource(bytes32 resourceHash) external view returns (Resource memory);
    function setFacilitatorFeeBps(uint16 newFeeBps) external;
}
