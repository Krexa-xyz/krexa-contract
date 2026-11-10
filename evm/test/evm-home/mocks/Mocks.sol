// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PackedUserOperation} from "../../../src/evm-home/interfaces/PackedUserOperation.sol";
import {IPolicy, IHook} from "../../../src/evm-home/interfaces/IERC7579Modules.sol";
import {SwapDecoder} from "../../../src/evm-home/lib/SwapDecoder.sol";
import {ExecDecoder} from "../../../src/evm-home/lib/ExecDecoder.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Chainlink-style feed with controllable answer, age and failure modes.
contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public broken; // latestRoundData reverts
    bool public shortReturn; // latestRoundData returns a wrong-sized payload

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setShort(bool b) external {
        shortReturn = b;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed broken");
        if (shortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev SwapRouter02-shaped router: pulls tokenIn from msg.sender, mints tokenOut to recipient at num/den.
contract MockSwapRouter {
    uint256 public num = 1;
    uint256 public den = 1;

    function setRate(uint256 n, uint256 d) external {
        num = n;
        den = d;
    }

    function exactInputSingle(SwapDecoder.SingleParams calldata p) external returns (uint256 out) {
        ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * num / den;
        require(out >= p.amountOutMinimum, "too little");
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

/// @dev Stand-in for Kernel v3.3 behaviour that matters here. Mirrors Kernel.sol `validateUserOp` (policy call
/// from the account), `executeUserOp` (hook.preCheck -> self-execute -> hook.postCheck) and the owner/root path
/// (no policy, no hook). `msg.sender` seen by modules is this contract, like the real account.
contract MockKernel {
    address public owner;
    IPolicy public policy;
    bytes32 public permId;
    IHook public hook;
    bool public moduleInstalled;

    error PolicyFailed();
    error ExecutionReverted();
    error InvalidCaller();
    error Expired();
    error NotYetValid();

    constructor(address owner_) {
        owner = owner_;
    }

    function wire(IPolicy p, bytes32 id, IHook h) external {
        policy = p;
        permId = id;
        hook = h;
    }

    // modules are installed by the account calling them (as Kernel does)
    function callModule(address m, bytes calldata data) external {
        require(msg.sender == owner);
        (bool ok, bytes memory r) = m.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    /// @dev session-key path: EntryPoint -> validateUserOp (policy) -> executeUserOp (hook around execute)
    function sessionOp(PackedUserOperation calldata op) external {
        uint256 vd = policy.checkUserOpPolicy(permId, op);
        if (address(uint160(vd)) != address(0)) revert PolicyFailed();
        // EntryPoint: validUntil (bits 160..207) and validAfter (bits 208..255); 0 validUntil means no expiry
        uint48 until = uint48(vd >> 160);
        if (until != 0 && block.timestamp > until) revert Expired();
        if (block.timestamp < uint48(vd >> 208)) revert NotYetValid();
        bytes calldata inner = op.callData[4:];
        bytes memory ctx;
        if (address(hook) != address(0)) ctx = hook.preCheck(msg.sender, 0, inner);
        (bool ok, bytes memory r) = address(this).call(inner);
        if (!ok) {
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }
        if (address(hook) != address(0)) hook.postCheck(ctx);
    }

    /// @dev owner path: root validator, no policy, no hook
    function ownerOp(bytes calldata callData) external {
        if (msg.sender != owner) revert InvalidCaller();
        (bool ok, bytes memory r) = address(this).call(callData);
        if (!ok) {
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    function execute(bytes32 mode, bytes calldata ec) external {
        if (msg.sender != address(this)) revert InvalidCaller();
        if (mode[0] == 0x00) {
            address target = address(bytes20(ec[0:20]));
            uint256 value = uint256(bytes32(ec[20:52]));
            (bool ok, bytes memory r) = target.call{value: value}(ec[52:]);
            if (!ok) {
                assembly {
                    revert(add(r, 0x20), mload(r))
                }
            }
        } else {
            ExecDecoder.Call[] memory cs = abi.decode(ec, (ExecDecoder.Call[]));
            for (uint256 i; i < cs.length; ++i) {
                (bool ok, bytes memory r) = cs[i].target.call{value: cs[i].value}(cs[i].data);
                if (!ok) {
                    assembly {
                        revert(add(r, 0x20), mload(r))
                    }
                }
            }
        }
    }

    /// @dev Kernel's `installModule` is `onlyEntryPointOrSelfOrRoot`: a self-call passes. Only the policy's
    /// target check stands between a session key and this function.
    function installModule(uint256, address, bytes calldata) external {
        if (msg.sender != address(this) && msg.sender != owner) revert InvalidCaller();
        moduleInstalled = true;
    }
}
