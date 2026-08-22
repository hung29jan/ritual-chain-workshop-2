// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IScheduler, IRitualWallet, ITEEServiceRegistry} from "../ritual/RitualChain.sol";

/** Test-only stand-ins placed at Ritual's canonical addresses with vm.etch. */
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
 * The real HTTP precompile returns raw bytes. Keeping this as fallback(bytes) avoids
 * the extra ABI layer a named Solidity function would add. The mock also decodes and
 * records the requested URL so tests can prove retry rotation reached the precompile.
 */
contract MockHTTPPrecompile {
    struct HTTPRequest {
        address executor;
        bytes[] encryptedSecrets;
        uint256 ttl;
        bytes[] secretSignatures;
        bytes userPublicKey;
        string url;
        uint8 method;
        string[] headerKeys;
        string[] headerValues;
        bytes body;
        uint256 dkmsKeyIndex;
        uint8 dkmsKeyFormat;
        bool piiEnabled;
    }

    uint16 public status;
    bytes public body;
    string public errorMessage;
    bool public forceRevert;
    string public lastUrl;

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

        HTTPRequest memory request = abi.decode(input, (HTTPRequest));
        lastUrl = request.url;

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

    // Solidity fallback functions cannot be declared view. The production contract
    // reaches this with STATICCALL, so this function deliberately performs no writes.
    fallback(bytes calldata) external returns (bytes memory) {
        if (returnEmpty) return bytes("");
        return abi.encode(parsedValue);
    }
}
