// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IScheduler, IRitualWallet, ITEEServiceRegistry} from "../ritual/RitualChain.sol";

/**
 * Test-only stand-ins for Ritual's canonical contracts/precompiles.
 *
 * The tests deploy these normally, copy their runtime code with vm.etch, and place it
 * at the exact Ritual addresses. Storage starts empty at the etched addresses and is
 * configured through the setters below.
 */

contract MockScheduler is IScheduler {
    uint256 public nextCallId;
    mapping(uint256 => uint8) public callState;

    function schedule(
        bytes calldata,
        uint32,
        uint32,
        uint32,
        uint32,
        uint32,
        uint256,
        uint256,
        uint256,
        address
    ) external returns (uint256 callId) {
        callId = ++nextCallId;
        callState[callId] = 0;
    }

    function cancel(uint256 callId) external {
        callState[callId] = 3;
    }

    function getCallState(uint256 callId) external view returns (uint8) {
        return callState[callId];
    }

    function approveScheduler(address) external {}

    /// Mimics Scheduler executionIndex injection at the semantic level for tests.
    function fire(address target, uint256 executionIndex, uint256 marketId) external {
        (bool ok, bytes memory reason) = target.call(
            abi.encodeWithSignature(
                "onScheduledResolve(uint256,uint256)",
                executionIndex,
                marketId
            )
        );
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract MockRitualWallet is IRitualWallet {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lockUntil;

    function deposit(uint256 lockDuration) external payable {
        _balances[msg.sender] += msg.value;
        _lockUntil[msg.sender] = block.number + lockDuration;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lockUntil(address account) external view returns (uint256) {
        return _lockUntil[account];
    }
}

contract MockTEERegistry is ITEEServiceRegistry {
    address public executor;
    bool public available;

    function configure(address executor_, bool available_) external {
        executor = executor_;
        available = available_;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external view returns (address teeAddress, bool found) {
        return (executor, available);
    }
}

/**
 * HTTP is a short-running async precompile. Its settled response is raw bytes, not an
 * ABI-encoded Solidity `bytes` return value. A fallback(bytes) return is intentional:
 * using a normal named Solidity function here adds an extra ABI layer and makes the
 * production decoder fail for the wrong reason.
 */
contract MockHTTPPrecompile {
    uint16 public status;
    bytes public body;
    string public errorMessage;
    bool public forceRevert;

    function configure(
        uint16 status_,
        bytes calldata body_,
        string calldata errorMessage_,
        bool forceRevert_
    ) external {
        status = status_;
        body = body_;
        errorMessage = errorMessage_;
        forceRevert = forceRevert_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (forceRevert) revert("mock HTTP failure");
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        bytes memory actualOutput = abi.encode(
            status,
            keys,
            values,
            body,
            errorMessage
        );
        return abi.encode(input, actualOutput);
    }
}

contract MockJQPrecompile {
    uint256 public parsedValue;
    bool public returnEmpty;

    function configure(uint256 value_, bool returnEmpty_) external {
        parsedValue = value_;
        returnEmpty = returnEmpty_;
    }

    fallback(bytes calldata) external view returns (bytes memory) {
        if (returnEmpty) return bytes("");
        return abi.encode(parsedValue);
    }
}
