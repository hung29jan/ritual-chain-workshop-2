// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * RitualPredict — a self-resolving binary prediction market.
 *
 * Users stake native RITUAL on YES or NO. At resolution the Ritual Scheduler wakes
 * the contract and each retry can use a different immutable oracle endpoint. A TEE
 * executor performs the HTTP request; the synchronous jq precompile extracts the
 * configured uint256 value; the contract compares it with the target and settles.
 */
contract RitualPredict {
    enum MarketState {
        Open,
        Closed,
        Resolving,
        Resolved,
        Invalid
    }

    enum Comparator {
        GT,
        GTE,
        LT,
        LTE
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    struct Market {
        uint256 id;
        address creator;
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        uint256 totalYes;
        uint256 totalNo;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        string invalidReason;
    }

    struct NewMarket {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;
    uint256 public constant HTTP_TTL_BLOCKS = 100;
    uint256 public constant EXECUTOR_PROBES = 8;
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    uint256 public immutable blockTimeMs;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;
    mapping(uint256 => string[]) private _fallbackOracleUrls;

    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        Comparator comparator
    );
    event FallbackOracleConfigured(
        uint256 indexed marketId,
        uint256 indexed fallbackIndex,
        string oracleUrl
    );
    event OracleAttemptSelected(
        uint256 indexed marketId,
        uint8 indexed attempt,
        string oracleUrl
    );
    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );
    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );
    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        string reason
    );
    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 observedValue
    );
    event MarketInvalidated(uint256 indexed marketId, string reason);
    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event StakeRefunded(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();
    error TooManyFallbackOracles();
    error DuplicateOracle();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;
        IScheduler(RitualChain.SCHEDULER).approveScheduler(
            RitualChain.SCHEDULER
        );
    }

    // ───────────────────────── Market lifecycle ──────────────────────────

    /// Backwards-compatible single-oracle market creation.
    function createMarket(
        NewMarket calldata p
    ) external returns (uint256 marketId) {
        string[] memory noFallbacks = new string[](0);
        return _createMarket(p, noFallbacks);
    }

    /**
     * Creates a market with immutable fallback endpoints. With MAX_ATTEMPTS=3, at most
     * two fallbacks are accepted. Attempt 1 uses the primary URL, attempt 2 fallback 1,
     * and attempt 3 fallback 2. If only one fallback is supplied, attempt 3 rotates
     * back to the primary URL.
     */
    function createMarketWithFallbacks(
        NewMarket calldata p,
        string[] calldata fallbackOracleUrls
    ) external returns (uint256 marketId) {
        string[] memory copied = fallbackOracleUrls;
        return _createMarket(p, copied);
    }

    function _createMarket(
        NewMarket calldata p,
        string[] memory fallbackOracleUrls
    ) private returns (uint256 marketId) {
        if (
            bytes(p.question).length == 0 ||
            bytes(p.oracleUrl).length == 0 ||
            bytes(p.jsonPath).length == 0
        ) revert EmptyString();

        if (
            p.bettingSeconds < MIN_BETTING_SECONDS ||
            p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            p.bettingSeconds > MAX_MARKET_SECONDS ||
            p.resolveDelaySeconds > MAX_MARKET_SECONDS ||
            p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS
        ) revert BadDuration();

        if (fallbackOracleUrls.length > MAX_ATTEMPTS - 1)
            revert TooManyFallbackOracles();

        bytes32 primaryHash = keccak256(bytes(p.oracleUrl));
        for (uint256 i = 0; i < fallbackOracleUrls.length; i++) {
            if (bytes(fallbackOracleUrls[i]).length == 0) revert EmptyString();
            bytes32 candidateHash = keccak256(bytes(fallbackOracleUrls[i]));
            if (candidateHash == primaryHash) revert DuplicateOracle();
            for (uint256 j = 0; j < i; j++) {
                if (
                    candidateHash ==
                    keccak256(bytes(fallbackOracleUrls[j]))
                ) revert DuplicateOracle();
            }
        }

        uint256 close = block.number + _secondsToBlocks(p.bettingSeconds);
        uint256 resolve = close + _secondsToBlocks(p.resolveDelaySeconds);
        if (resolve > type(uint32).max) revert BadDuration();

        marketId = marketCount + 1;
        marketCount = marketId;

        Market storage m = _markets[marketId];
        m.id = marketId;
        m.creator = msg.sender;
        m.question = p.question;
        m.oracleUrl = p.oracleUrl;
        m.jsonPath = p.jsonPath;
        m.target = p.target;
        m.comparator = p.comparator;
        m.closeBlock = uint64(close);
        m.resolveBlock = uint64(resolve);
        m.state = MarketState.Open;
        m.outcome = Outcome.Unresolved;

        for (uint256 i = 0; i < fallbackOracleUrls.length; i++) {
            _fallbackOracleUrls[marketId].push(fallbackOracleUrls[i]);
            emit FallbackOracleConfigured(
                marketId,
                i,
                fallbackOracleUrls[i]
            );
        }

        m.scheduleId = _scheduleResolution(marketId, m.resolveBlock);

        emit MarketCreated(
            marketId,
            msg.sender,
            p.question,
            m.closeBlock,
            m.resolveBlock,
            m.scheduleId
        );
        emit ResolutionRuleSet(
            marketId,
            p.oracleUrl,
            p.jsonPath,
            p.target,
            p.comparator
        );
    }

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock)
            revert BettingClosed();

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();

        Market storage m = _markets[marketId];
        if (m.closeBlock == 0) return;
        if (m.state == MarketState.Resolved || m.state == MarketState.Invalid)
            return;
        if (block.number < m.resolveBlock || m.attempts >= MAX_ATTEMPTS) return;

        uint8 attempt = m.attempts + 1;
        m.attempts = attempt;
        m.state = MarketState.Resolving;

        string memory selectedOracle = _oracleUrlForAttempt(
            marketId,
            m.oracleUrl,
            attempt
        );
        emit OracleAttemptSelected(marketId, attempt, selectedOracle);

        address executor = _pickExecutor(marketId, executionIndex);
        emit ResolutionAttempted(marketId, attempt, executor);

        if (executor == address(0)) {
            _fail(m, marketId, attempt, "no HTTP executor available");
            return;
        }

        (bool ok, uint256 observed, string memory reason) = _readOracle(
            m,
            executor,
            selectedOracle
        );
        if (!ok) {
            _fail(m, marketId, attempt, reason);
            return;
        }

        m.observedValue = observed;
        bool yesWon = _compare(observed, m.target, m.comparator);
        m.outcome = yesWon ? Outcome.Yes : Outcome.No;

        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (winningPool == 0) {
            _invalidate(m, marketId, "winning side has no stake");
            return;
        }

        m.state = MarketState.Resolved;
        emit MarketResolved(marketId, m.outcome, observed);

        // Best-effort cancellation preserves a valid result if Scheduler.cancel fails.
        RitualChain.SCHEDULER.call(
            abi.encodeCall(IScheduler.cancel, (m.scheduleId))
        );
    }

    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        string memory reason
    ) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        emit MarketInvalidated(marketId, reason);
    }

    // ────────────────────────────── Payouts ──────────────────────────────

    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStake[marketId][msg.sender] +
            noStake[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStake[marketId][account]
            : noStake[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        return (stake * (m.totalYes + m.totalNo)) / winningPool;
    }

    // ─────────────────────────────── Views ───────────────────────────────

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        if (m.state == MarketState.Open && block.number >= m.closeBlock)
            m.state = MarketState.Closed;
    }

    function getMarkets() external view returns (Market[] memory all) {
        uint256 total = marketCount;
        all = new Market[](total);
        for (uint256 i = 0; i < total; i++) {
            all[i] = getMarket(total - i);
        }
    }

    /// Returns primary first, then immutable fallbacks in retry order.
    function getOracleUrls(
        uint256 marketId
    ) external view returns (string[] memory urls) {
        Market storage m = _market(marketId);
        uint256 fallbackCount = _fallbackOracleUrls[marketId].length;
        urls = new string[](fallbackCount + 1);
        urls[0] = m.oracleUrl;
        for (uint256 i = 0; i < fallbackCount; i++) {
            urls[i + 1] = _fallbackOracleUrls[marketId][i];
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStake[marketId][account],
            noStake[marketId][account],
            settled[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.state == MarketState.Resolved)
            claimable = _payout(m, marketId, account);
        else if (m.state == MarketState.Invalid) claimable = yes + no;
    }

    // ───────────────────────── Execution funding ─────────────────────────

    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return
            IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    // ───────────────────── Ritual: oracle read path ──────────────────────

    function _oracleUrlForAttempt(
        uint256 marketId,
        string storage primaryOracle,
        uint8 attempt
    ) private view returns (string memory) {
        uint256 fallbackCount = _fallbackOracleUrls[marketId].length;
        uint256 oracleCount = fallbackCount + 1;
        uint256 selected = (uint256(attempt) - 1) % oracleCount;
        if (selected == 0) return primaryOracle;
        return _fallbackOracleUrls[marketId][selected - 1];
    }

    function _readOracle(
        Market storage m,
        address executor,
        string memory oracleUrl
    ) private returns (bool ok, uint256 value, string memory reason) {
        bytes[] memory emptyBytes = new bytes[](0);
        string[] memory emptyStrings = new string[](0);

        bytes memory request = abi.encode(
            executor,
            emptyBytes,
            HTTP_TTL_BLOCKS,
            emptyBytes,
            bytes(""),
            oracleUrl,
            RitualChain.HTTP_GET,
            emptyStrings,
            emptyStrings,
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );

        (bool callOk, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(
            request
        );
        if (!callOk) return (false, 0, "HTTP precompile call failed");

        try this.decodeHttpResponse(raw) returns (
            uint16 status,
            bytes memory body,
            string memory errorMessage
        ) {
            if (bytes(errorMessage).length != 0)
                return (false, 0, errorMessage);
            if (status != 200) return (false, 0, "HTTP status is not 200");
            if (body.length == 0) return (false, 0, "HTTP body is empty");

            (bool jqOk, uint256 parsed) = _jqUint(
                m.jsonPath,
                string(body)
            );
            if (!jqOk) return (false, 0, "jq could not parse uint256");
            return (true, parsed, "");
        } catch {
            return (false, 0, "malformed HTTP response");
        }
    }

    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _pickExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        uint256 seed = uint256(
            keccak256(
                abi.encode(
                    block.prevrandao,
                    block.number,
                    marketId,
                    executionIndex,
                    address(this)
                )
            )
        );

        (bool ok, bytes memory result) = RitualChain.TEE_SERVICE_REGISTRY
            .staticcall(
                abi.encodeCall(
                    ITEEServiceRegistry.pickServiceByCapability,
                    (
                        RitualChain.CAPABILITY_HTTP_CALL,
                        true,
                        seed,
                        EXECUTOR_PROBES
                    )
                )
            );

        if (!ok || result.length < 64) return address(0);
        (address executor, bool found) = abi.decode(result, (address, bool));
        return found ? executor : address(0);
    }

    // ────────────────────── Ritual: scheduling ───────────────────────────

    function _scheduleResolution(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        bytes memory data = abi.encodeWithSelector(
            this.onScheduledResolve.selector,
            uint256(0),
            marketId
        );

        uint256 maxPriorityFeePerGas = MIN_MAX_FEE_PER_GAS;
        uint256 maxFeePerGas = block.basefee + maxPriorityFeePerGas;

        callId = IScheduler(RitualChain.SCHEDULER).schedule(
            data,
            RESOLVE_GAS_LIMIT,
            uint32(resolveBlock),
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            maxFeePerGas,
            maxPriorityFeePerGas,
            0,
            address(this)
        );
    }

    // ────────────────────────────── Helpers ──────────────────────────────

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) private pure returns (bool) {
        if (comparator == Comparator.GT) return observed > target;
        if (comparator == Comparator.GTE) return observed >= target;
        if (comparator == Comparator.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
