// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Relayer} from "src/test/Relayer.sol";
import {PromiseCallback} from "src/PromiseCallback.sol";
import {CrosschainSwapper} from "src/CrosschainSwapper.sol";
import {Validator} from "src/Validator.sol";
import {SuperchainTokenBridge} from "src/SuperchainTokenBridge.sol";
import {PredeployAddresses} from "src/libraries/PredeployAddresses.sol";
import {IL2ToL2CrossDomainMessenger} from "src/interfaces/IL2ToL2CrossDomainMessenger.sol";

// Import mock contracts
import {MockSuperchainERC20} from "test/examples/utils/MockSuperchainERC20.sol";
import {MockExchange} from "test/examples/utils/MockExchange.sol";

/// @title BridgeSwapBridge
/// @notice E2E test demonstrating CrosschainSwapper cross-chain swap workflow
/// @dev Flow: Chain A initSwap -> Chain B relaySwap -> Chain B bridgeBack -> Chain A
contract BridgeSwapBridgeTest is Test, Relayer {
    // Promise system contracts (deployed on both chains)
    PromiseCallback public promiseCallbackA;
    PromiseCallback public promiseCallbackB;

    // Validator contracts
    Validator public validatorA;
    Validator public validatorB;

    // CrosschainSwapper contracts
    CrosschainSwapper public crosschainSwapperA;
    CrosschainSwapper public crosschainSwapperB;

    // SuperchainTokenBridge contracts
    SuperchainTokenBridge public tokenBridgeA;
    SuperchainTokenBridge public tokenBridgeB;

    // Mock router (exchange) contracts
    MockExchange public routerA;
    MockExchange public routerB;

    // Test tokens (same addresses on both chains)
    MockSuperchainERC20 public tokenIn; // Input token (e.g., USDC)
    MockSuperchainERC20 public tokenOut; // Output token (e.g., WETH)

    // Test participants
    address public user;
    address public liquidityProvider;

    // Test parameters
    uint256 public swapAmount = 100 ether;
    uint256 public minAmountOut = 95 ether; // 5% slippage tolerance

    // Test state tracking
    uint256 public initialTokenInBalanceA;
    uint256 public initialTokenOutBalanceA;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        user = makeAddr("user");
        liquidityProvider = makeAddr("liquidityProvider");

        // Make addresses persistent across forks
        vm.makePersistent(user);
        vm.makePersistent(liquidityProvider);

        // Deploy PromiseCallback contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        promiseCallbackA = new PromiseCallback{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        promiseCallbackB = new PromiseCallback{salt: bytes32(0)}();

        // Verify same addresses
        require(
            address(promiseCallbackA) == address(promiseCallbackB), "PromiseCallback contracts must have same address"
        );

        // Deploy Validator contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        validatorA = new Validator{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        validatorB = new Validator{salt: bytes32(0)}();

        // Verify same addresses
        require(address(validatorA) == address(validatorB), "Validator contracts must have same address");

        // Use predeploy SuperchainTokenBridge addresses
        tokenBridgeA = SuperchainTokenBridge(PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE);
        tokenBridgeB = SuperchainTokenBridge(PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE);

        // Deploy Mock Router (Exchange) contracts
        vm.selectFork(forkIds[0]);
        routerA = new MockExchange{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        routerB = new MockExchange{salt: bytes32(0)}();

        // Deploy CrosschainSwapper contracts
        vm.selectFork(forkIds[0]);
        crosschainSwapperA =
            new CrosschainSwapper{salt: bytes32(0)}(address(promiseCallbackA), address(routerA), address(validatorA));

        vm.selectFork(forkIds[1]);
        crosschainSwapperB =
            new CrosschainSwapper{salt: bytes32(0)}(address(promiseCallbackB), address(routerB), address(validatorB));

        // Verify same addresses
        require(
            address(crosschainSwapperA) == address(crosschainSwapperB),
            "CrosschainSwapper contracts must have same address"
        );

        // Deploy tokens with same addresses and predeploy bridge as authorized minter
        vm.selectFork(forkIds[0]);
        tokenIn = new MockSuperchainERC20{salt: bytes32(0)}(
            "TokenIn", "TIN", 1000000 ether, PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE
        );
        tokenOut = new MockSuperchainERC20{salt: bytes32(0)}(
            "TokenOut", "TOUT", 1000000 ether, PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE
        );

        vm.selectFork(forkIds[1]);
        MockSuperchainERC20 tokenInB = new MockSuperchainERC20{salt: bytes32(0)}(
            "TokenIn", "TIN", 1000000 ether, PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE
        );
        MockSuperchainERC20 tokenOutB = new MockSuperchainERC20{salt: bytes32(0)}(
            "TokenOut", "TOUT", 1000000 ether, PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE
        );

        // Verify same addresses
        require(address(tokenIn) == address(tokenInB), "TokenIn must have same address");
        require(address(tokenOut) == address(tokenOutB), "TokenOut must have same address");

        // Set up initial token distribution and router liquidity
        setupTokensAndLiquidity();

        // Store initial balances
        vm.selectFork(forkIds[0]);
        initialTokenInBalanceA = tokenIn.balanceOf(user);
        initialTokenOutBalanceA = tokenOut.balanceOf(user);
    }

    function setupTokensAndLiquidity() internal {
        // Chain A setup
        vm.selectFork(forkIds[0]);

        // Transfer tokens to user and liquidity provider
        tokenIn.transfer(user, 1000 ether); // User gets input tokens
        tokenOut.transfer(liquidityProvider, 20000 ether); // LP gets output tokens for liquidity
        tokenIn.transfer(liquidityProvider, 10000 ether); // LP gets input tokens for liquidity

        // Setup Chain A router liquidity (for potential future operations)
        vm.startPrank(liquidityProvider);
        tokenIn.approve(address(routerA), 5000 ether);
        tokenOut.approve(address(routerA), 5000 ether);
        routerA.provideLiquidity(address(tokenIn), 5000 ether);
        routerA.provideLiquidity(address(tokenOut), 5000 ether);
        routerA.addPair(address(tokenIn), address(tokenOut), 10000); // 1:1 rate
        routerA.addPair(address(tokenOut), address(tokenIn), 10000); // Reverse pair
        vm.stopPrank();

        // Chain B setup
        vm.selectFork(forkIds[1]);

        // Transfer tokens for Chain B liquidity
        tokenIn.transfer(liquidityProvider, 10000 ether); // LP gets input tokens
        tokenOut.transfer(liquidityProvider, 10000 ether); // LP gets output tokens

        // Setup Chain B router liquidity (this is where the swap happens)
        vm.startPrank(liquidityProvider);
        tokenIn.approve(address(routerB), 5000 ether);
        tokenOut.approve(address(routerB), 5000 ether);
        routerB.provideLiquidity(address(tokenIn), 5000 ether);
        routerB.provideLiquidity(address(tokenOut), 5000 ether);
        routerB.addPair(address(tokenIn), address(tokenOut), 10000); // 1:1 rate
        routerB.addPair(address(tokenOut), address(tokenIn), 10000); // Reverse pair
        vm.stopPrank();
    }

    /// @notice Test successful cross-chain swap using CrosschainSwapper
    /// @dev Flow: Chain A initSwap -> Chain B relaySwap -> Chain B bridgeBack -> Chain A
    function test_CrosschainSwapper_CrossChainSwap_Success() public {
        console.log("=== Testing CrosschainSwapper Cross-Chain Swap Success ===");
        console.log("Flow: Chain A initSwap -> Chain B relaySwap -> Chain B bridgeBack -> Chain A");
        console.log("");

        // ========================================
        // PHASE 1: CHAIN A - USER CALLS INIT SWAP
        // ========================================
        console.log("PHASE 1: CHAIN A - USER CALLS INIT SWAP");

        vm.selectFork(forkIds[0]);
        vm.startPrank(user);

        // Approve tokens for CrosschainSwapper
        tokenIn.approve(address(crosschainSwapperA), swapAmount);

        // Call initSwap to start the cross-chain swap
        console.log("Calling initSwap on Chain A");
        (bytes32 bridgeId, bytes32 bridgeBackId, bytes32 bridgeBackOnErrorId, bytes32 afterBridgeBackId) =
        crosschainSwapperA.initSwap(
            chainIdByForkId[forkIds[1]], // Destination chain (Chain B)
            address(tokenIn), // Token to swap from
            address(tokenOut), // Token to swap to
            swapAmount, // Amount to swap
            minAmountOut, // Minimum amount out
            user // Recipient
        );

        vm.stopPrank();

        console.log("initSwap completed:");
        console.log("  bridgeId:", uint256(bridgeId));
        console.log("  bridgeBackId:", uint256(bridgeBackId));
        console.log("  bridgeBackOnErrorId:", uint256(bridgeBackOnErrorId));
        console.log("  afterBridgeBackId:", uint256(afterBridgeBackId));
        console.log("");

        // ========================================
        // PHASE 2: RELAY MESSAGES
        // ========================================
        console.log("PHASE 2: RELAY MESSAGES");
        console.log("Relaying cross-chain messages from Chain A to Chain B");

        relayAllMessages();
        console.log("Messages relayed successfully");
        console.log("");

        // ========================================
        // PHASE 3: CHAIN B - RESOLVE BRIDGE PROMISE TO EXECUTE RELAYSWAP
        // ========================================
        console.log("PHASE 3: CHAIN B - RESOLVE BRIDGE PROMISE TO EXECUTE RELAYSWAP");

        vm.selectFork(forkIds[1]);

        // Check if bridge promise can be resolved
        if (promiseCallbackB.canResolve(bridgeId)) {
            console.log("Resolving bridge promise on Chain B");
            promiseCallbackB.resolve(bridgeId);
            console.log("Bridge promise resolved - relaySwap executed");
        } else {
            console.log("Bridge promise not ready for resolution");
        }

        // Check the status of the bridge promise
        PromiseCallback.Promise memory bridgePromise = promiseCallbackB.getPromise(bridgeId);
        console.log("Bridge promise status:", uint256(bridgePromise.status));
        console.log("CrosschainSwapper tokenOut balance:", tokenOut.balanceOf(address(crosschainSwapperB)));
        console.log("");

        // ========================================
        // PHASE 4: CHAIN B - RESOLVE BRIDGE BACK PROMISE
        // ========================================
        console.log("PHASE 4: CHAIN B - RESOLVE BRIDGE BACK PROMISE");

        // Check if bridge back promise can be resolved
        if (promiseCallbackB.canResolve(bridgeBackId)) {
            console.log("Resolving bridge back promise on Chain B");
            promiseCallbackB.resolve(bridgeBackId);
            console.log("Bridge back promise resolved - bridgeBack executed");
        } else {
            console.log("Bridge back promise not ready for resolution");
        }

        // Check the status of the bridge back promise
        PromiseCallback.Promise memory bridgeBackPromise = promiseCallbackB.getPromise(bridgeBackId);
        console.log("Bridge back promise status:", uint256(bridgeBackPromise.status));
        console.log("");

        // ========================================
        // PHASE 5: RELAY FINAL MESSAGES
        // ========================================
        console.log("PHASE 5: RELAY FINAL MESSAGES");
        console.log("Relaying cross-chain messages from Chain B to Chain A");

        relayAllMessages();
        console.log("Final messages relayed successfully");

        // Process the bridge message on Chain A to mint tokens
        vm.selectFork(forkIds[0]);
        console.log("Processing bridge message on Chain A");
        relayAllMessages();
        console.log("");

        // ========================================
        // PHASE 6: SHARE RESOLVED BRIDGE BACK PROMISE TO CHAIN A
        // ========================================
        console.log("PHASE 6: SHARE RESOLVED BRIDGE BACK PROMISE TO CHAIN A");

        // Switch back to Chain B to share the resolved bridgeBackId promise
        vm.selectFork(forkIds[1]);
        console.log("Sharing resolved bridgeBackId promise from Chain B to Chain A");
        promiseCallbackB.sharePromise(chainIdByForkId[forkIds[0]], bridgeBackId);
        console.log("Bridge back promise shared successfully");

        // Relay the share message to Chain A
        relayAllMessages();
        console.log("Share message relayed to Chain A");

        // ========================================
        // PHASE 7: CHAIN A - RESOLVE AFTER BRIDGE BACK PROMISE
        // ========================================
        console.log("PHASE 7: CHAIN A - RESOLVE AFTER BRIDGE BACK PROMISE");

        vm.selectFork(forkIds[0]);

        // Check if afterBridgeBackId promise can be resolved
        if (promiseCallbackA.canResolve(afterBridgeBackId)) {
            console.log("Resolving afterBridgeBackId promise on Chain A");
            promiseCallbackA.resolve(afterBridgeBackId);
            console.log("After bridge back promise resolved successfully");
        } else {
            console.log("After bridge back promise not ready for resolution");
        }

        // Check the status of the after bridge back promise
        PromiseCallback.Promise memory afterBridgeBackPromise = promiseCallbackA.getPromise(afterBridgeBackId);
        console.log("After bridge back promise status:", uint256(afterBridgeBackPromise.status));
        console.log("");

        // ========================================
        // PHASE 8: VERIFICATION
        // ========================================
        console.log("PHASE 8: VERIFICATION");

        // Verify final balances on Chain A
        vm.selectFork(forkIds[0]);
        uint256 finalTokenInBalanceA = tokenIn.balanceOf(user);
        uint256 finalTokenOutBalanceA = tokenOut.balanceOf(user);

        console.log("Chain A - TokenIn balance change:", int256(finalTokenInBalanceA) - int256(initialTokenInBalanceA));
        console.log(
            "Chain A - TokenOut balance change:", int256(finalTokenOutBalanceA) - int256(initialTokenOutBalanceA)
        );

        // Verify final balances on Chain B
        vm.selectFork(forkIds[1]);
        uint256 finalTokenInBalanceB = tokenIn.balanceOf(user);
        uint256 finalTokenOutBalanceB = tokenOut.balanceOf(user);

        console.log("Chain B - TokenIn balance:", finalTokenInBalanceB);
        console.log("Chain B - TokenOut balance:", finalTokenOutBalanceB);

        // Verify success conditions
        assertEq(
            finalTokenInBalanceA,
            initialTokenInBalanceA - swapAmount,
            "TokenIn on Chain A should be reduced by swap amount"
        );
        assertGt(finalTokenOutBalanceA, initialTokenOutBalanceA, "TokenOut on Chain A should be increased");
        assertEq(finalTokenInBalanceB, 0, "TokenIn on Chain B should be 0 (swapped)");
        assertEq(finalTokenOutBalanceB, 0, "TokenOut on Chain B should be 0 (bridged back)");

        console.log("");
        console.log("SUCCESS: Cross-chain swap completed successfully!");
        console.log("Flow: TokenIn (A) -> Bridge -> TokenIn (B) -> Swap -> TokenOut (B) -> Bridge -> TokenOut (A)");
    }

    /// @notice Test cross-chain swap failure and error handling
    /// @dev Flow: Chain A initSwap -> Chain B relaySwap (fails) -> Chain B bridgeBackOnError -> Chain A
    function test_CrosschainSwapper_CrossChainSwap_Failure() public {
        console.log("=== Testing CrosschainSwapper Cross-Chain Swap Failure ===");
        console.log("Flow: Chain A initSwap -> Chain B relaySwap (fails) -> Chain B bridgeBackOnError -> Chain A");
        console.log("");

        // ========================================
        // PHASE 1: CHAIN A - USER CALLS INIT SWAP WITH INVALID PARAMETERS
        // ========================================
        console.log("PHASE 1: CHAIN A - USER CALLS INIT SWAP WITH INVALID PARAMETERS");

        vm.selectFork(forkIds[0]);
        vm.startPrank(user);

        // Approve tokens for CrosschainSwapper
        tokenIn.approve(address(crosschainSwapperA), swapAmount);

        // Call initSwap with impossibly high minAmountOut to trigger failure
        uint256 impossibleMinAmountOut = 1000 ether; // Much higher than what the swap can provide
        console.log("Calling initSwap on Chain A with impossibly high minAmountOut");
        (bytes32 bridgeId, bytes32 bridgeBackId, bytes32 bridgeBackOnErrorId, bytes32 afterBridgeBackId) =
        crosschainSwapperA.initSwap(
            chainIdByForkId[forkIds[1]], // Destination chain (Chain B)
            address(tokenIn), // Token to swap from
            address(tokenOut), // Token to swap to
            swapAmount, // Amount to swap
            impossibleMinAmountOut, // Impossibly high minimum amount out
            user // Recipient
        );

        vm.stopPrank();

        console.log("initSwap completed:");
        console.log("  bridgeId:", uint256(bridgeId));
        console.log("  bridgeBackId:", uint256(bridgeBackId));
        console.log("  bridgeBackOnErrorId:", uint256(bridgeBackOnErrorId));
        console.log("");

        // ========================================
        // PHASE 2: RELAY MESSAGES
        // ========================================
        console.log("PHASE 2: RELAY MESSAGES");
        console.log("Relaying cross-chain messages from Chain A to Chain B");

        relayAllMessages();
        console.log("Messages relayed successfully");
        console.log("");

        // ========================================
        // PHASE 3: CHAIN B - RESOLVE BRIDGE PROMISE (WILL FAIL)
        // ========================================
        console.log("PHASE 3: CHAIN B - RESOLVE BRIDGE PROMISE (WILL FAIL)");

        vm.selectFork(forkIds[1]);

        // Check if bridge promise can be resolved
        if (promiseCallbackB.canResolve(bridgeId)) {
            console.log("Resolving bridge promise on Chain B (expecting failure)");
            promiseCallbackB.resolve(bridgeId);
            console.log("Bridge promise resolved - relaySwap executed but should have failed");
        } else {
            console.log("Bridge promise not ready for resolution");
        }

        // Check the status of the bridge promise (should be rejected)
        PromiseCallback.Promise memory bridgePromise = promiseCallbackB.getPromise(bridgeId);
        console.log("Bridge promise status:", uint256(bridgePromise.status));
        console.log("");

        // ========================================
        // PHASE 4: CHAIN B - RESOLVE ERROR HANDLER PROMISE
        // ========================================
        console.log("PHASE 4: CHAIN B - RESOLVE ERROR HANDLER PROMISE");

        // Check if error handler promise can be resolved
        if (promiseCallbackB.canResolve(bridgeBackOnErrorId)) {
            console.log("Resolving error handler promise on Chain B");
            promiseCallbackB.resolve(bridgeBackOnErrorId);
            console.log("Error handler promise resolved - bridgeBackOnError executed");
        } else {
            console.log("Error handler promise not ready for resolution");
        }

        // Check the status of the error handler promise
        PromiseCallback.Promise memory errorPromise = promiseCallbackB.getPromise(bridgeBackOnErrorId);
        console.log("Error handler promise status:", uint256(errorPromise.status));
        console.log("");

        // ========================================
        // PHASE 5: RELAY FINAL MESSAGES
        // ========================================
        console.log("PHASE 5: RELAY FINAL MESSAGES");
        console.log("Relaying cross-chain messages from Chain B to Chain A");

        relayAllMessages();
        console.log("Final messages relayed successfully");

        // Process the bridge message on Chain A to mint refund tokens
        vm.selectFork(forkIds[0]);
        console.log("Processing bridge message on Chain A");
        relayAllMessages();
        console.log("");

        // ========================================
        // PHASE 6: VERIFICATION
        // ========================================
        console.log("PHASE 6: VERIFICATION");

        // Verify final balances on Chain A (should be refunded)
        vm.selectFork(forkIds[0]);
        uint256 finalTokenInBalanceA = tokenIn.balanceOf(user);
        uint256 finalTokenOutBalanceA = tokenOut.balanceOf(user);

        console.log("Chain A - TokenIn balance change:", int256(finalTokenInBalanceA) - int256(initialTokenInBalanceA));
        console.log(
            "Chain A - TokenOut balance change:", int256(finalTokenOutBalanceA) - int256(initialTokenOutBalanceA)
        );

        // Verify final balances on Chain B
        vm.selectFork(forkIds[1]);
        uint256 finalTokenInBalanceB = tokenIn.balanceOf(user);
        uint256 finalTokenOutBalanceB = tokenOut.balanceOf(user);

        console.log("Chain B - TokenIn balance:", finalTokenInBalanceB);
        console.log("Chain B - TokenOut balance:", finalTokenOutBalanceB);

        // Verify refund conditions
        assertEq(
            finalTokenInBalanceA, initialTokenInBalanceA, "TokenIn on Chain A should be refunded (same as initial)"
        );
        assertEq(finalTokenOutBalanceA, initialTokenOutBalanceA, "TokenOut on Chain A should be unchanged");
        assertEq(finalTokenInBalanceB, 0, "TokenIn on Chain B should be 0");
        assertEq(finalTokenOutBalanceB, 0, "TokenOut on Chain B should be 0");

        console.log("");
        console.log("SUCCESS: Cross-chain swap failure handled correctly with refund!");
        console.log("Flow: TokenIn (A) -> Bridge -> TokenIn (B) -> Swap (fail) -> TokenIn (B) -> Bridge -> TokenIn (A)");
    }
}
