// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";
import {
    MockScheduler,
    MockRitualWallet,
    MockTEERegistry,
    MockHTTPPrecompile,
    MockJQPrecompile
} from "./mocks/RitualMocks.sol";

contract RitualPredictTest is Test {
    address internal constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address internal constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address internal constant TEE_REGISTRY = 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F;
    address internal constant HTTP = 0x0000000000000000000000000000000000000801;
    address internal constant JQ = 0x0000000000000000000000000000000000000803;

    address internal constant EXECUTOR = address(0xE1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    RitualPredict internal predict;

    function setUp() public {
        _etchCanonicalMocks();
        MockTEERegistry(TEE_REGISTRY).configure(EXECUTOR, true);
        MockHTTPPrecompile(HTTP).configure(200, bytes('{"price":4000}'), "", false);
        MockJQPrecompile(JQ).configure(4000, false);

        // 1000 ms makes the seconds-to-blocks conversion easy to reason about locally.
        predict = new RitualPredict(1000);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _etchCanonicalMocks() internal {
        MockScheduler schedulerImpl = new MockScheduler();
        MockRitualWallet walletImpl = new MockRitualWallet();
        MockTEERegistry registryImpl = new MockTEERegistry();
        MockHTTPPrecompile httpImpl = new MockHTTPPrecompile();
        MockJQPrecompile jqImpl = new MockJQPrecompile();

        vm.etch(SCHEDULER, address(schedulerImpl).code);
        vm.etch(RITUAL_WALLET, address(walletImpl).code);
        vm.etch(TEE_REGISTRY, address(registryImpl).code);
        vm.etch(HTTP, address(httpImpl).code);
        vm.etch(JQ, address(jqImpl).code);
    }

    function _params() internal pure returns (RitualPredict.NewMarket memory p) {
        p = RitualPredict.NewMarket({
            question: "Will ETH/USD be at least 4000?",
            oracleUrl: "https://oracle.example/eth",
            jsonPath: ".price",
            target: 4000,
            comparator: RitualPredict.Comparator.GTE,
            bettingSeconds: 30,
            resolveDelaySeconds: 15
        });
    }

    function _create() internal returns (uint256 marketId) {
        marketId = predict.createMarket(_params());
    }

    function _rollToResolve(uint256 marketId) internal {
        RitualPredict.Market memory market = predict.getMarket(marketId);
        vm.roll(market.resolveBlock);
    }

    function _fire(uint256 marketId, uint256 executionIndex) internal {
        MockScheduler(SCHEDULER).fire(address(predict), executionIndex, marketId);
    }

    function testCreateMarketSchedulesResolution() public {
        uint256 marketId = _create();
        RitualPredict.Market memory market = predict.getMarket(marketId);

        assertEq(marketId, 1);
        assertEq(predict.marketCount(), 1);
        assertEq(market.creator, address(this));
        assertEq(market.scheduleId, 1);
        assertGt(market.closeBlock, block.number);
        assertGt(market.resolveBlock, market.closeBlock);
    }

    function testRejectsBadMarketInput() public {
        RitualPredict.NewMarket memory p = _params();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);

        p = _params();
        p.bettingSeconds = 29;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function testBettingClosesByBlockNumber() public {
        uint256 marketId = _create();
        RitualPredict.Market memory market = predict.getMarket(marketId);

        vm.prank(alice);
        predict.bet{value: 1 ether}(marketId, true);

        vm.roll(market.closeBlock);
        vm.prank(bob);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(marketId, false);
    }

    function testOnlyCanonicalSchedulerCanResolve() public {
        uint256 marketId = _create();
        _rollToResolve(marketId);

        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, marketId);
    }

    function testSuccessfulResolutionAndPullPayout() public {
        uint256 marketId = _create();

        vm.prank(alice);
        predict.bet{value: 1 ether}(marketId, true);
        vm.prank(bob);
        predict.bet{value: 3 ether}(marketId, false);

        _rollToResolve(marketId);
        _fire(marketId, 0);

        RitualPredict.Market memory market = predict.getMarket(marketId);
        assertEq(uint256(market.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(market.outcome), uint256(RitualPredict.Outcome.Yes));
        assertEq(market.observedValue, 4000);
        assertEq(market.attempts, 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(marketId);
        assertEq(alice.balance - before, 4 ether);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(marketId);
    }

    function testOracleFailureRetriesThenRefunds() public {
        uint256 marketId = _create();
        vm.prank(alice);
        predict.bet{value: 2 ether}(marketId, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(marketId, false);

        MockHTTPPrecompile(HTTP).configure(500, bytes("upstream down"), "", false);
        _rollToResolve(marketId);

        _fire(marketId, 0);
        _fire(marketId, 1);
        _fire(marketId, 2);

        RitualPredict.Market memory market = predict.getMarket(marketId);
        assertEq(uint256(market.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(market.attempts, 3);

        uint256 before = alice.balance;
        vm.prank(alice);
        predict.claimRefund(marketId);
        assertEq(alice.balance - before, 2 ether);
    }

    function testEmptyWinningSideInvalidatesInsteadOfDividingByZero() public {
        uint256 marketId = _create();
        vm.prank(bob);
        predict.bet{value: 1 ether}(marketId, false);

        _rollToResolve(marketId);
        _fire(marketId, 0);

        RitualPredict.Market memory market = predict.getMarket(marketId);
        assertEq(uint256(market.outcome), uint256(RitualPredict.Outcome.Yes));
        assertEq(uint256(market.state), uint256(RitualPredict.MarketState.Invalid));
    }

    function testNoExecutorIsARecoverableAttemptFailure() public {
        uint256 marketId = _create();
        vm.prank(alice);
        predict.bet{value: 1 ether}(marketId, true);

        MockTEERegistry(TEE_REGISTRY).configure(address(0), false);
        _rollToResolve(marketId);
        _fire(marketId, 0);

        RitualPredict.Market memory market = predict.getMarket(marketId);
        assertEq(uint256(market.state), uint256(RitualPredict.MarketState.Resolving));
        assertEq(market.attempts, 1);
    }

    function testJqEmptyOutputDoesNotBecomeZeroPrice() public {
        uint256 marketId = _create();
        vm.prank(alice);
        predict.bet{value: 1 ether}(marketId, true);

        MockJQPrecompile(JQ).configure(0, true);
        _rollToResolve(marketId);
        _fire(marketId, 0);

        RitualPredict.Market memory market = predict.getMarket(marketId);
        assertEq(uint256(market.state), uint256(RitualPredict.MarketState.Resolving));
        assertEq(market.attempts, 1);
        assertEq(market.observedValue, 0);
    }
}
