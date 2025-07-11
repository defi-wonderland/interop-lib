// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Relayer} from "src/test/Relayer.sol";
import {Promise} from "src/Promise.sol";
import {UnifiedCallback} from "src/UnifiedCallback.sol";
import {CrosschainSwapper} from "src/CrosschainSwapper.sol";
import {SuperchainTokenBridge} from "src/SuperchainTokenBridge.sol";
import {PredeployAddresses} from "src/libraries/PredeployAddresses.sol";

// Import mock contracts
import {MockSuperchainERC20} from "test/examples/utils/MockSuperchainERC20.sol";
import {MockExchange} from "test/examples/utils/MockExchange.sol";

/// @title CrosschainSwapperE2E
/// @notice E2E test demonstrating CrosschainSwapper cross-chain swap workflow
/// @dev Flow: Chain A initSwap -> Chain B relaySwap -> Chain B bridgeBack -> Chain A
contract CrosschainSwapperE2ETest is Test, Relayer {
    // Promise system contracts (deployed on both chains)
    Promise public promiseA;
    Promise public promiseB;

    // CrosschainSwapper contracts
    CrosschainSwapper public CrosschainSwapperA;
    CrosschainSwapper public CrosschainSwapperB;

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

        // Deploy Promise contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

        // Verify same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");

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
        CrosschainSwapperA = new CrosschainSwapper{salt: bytes32(0)}(address(routerA), address(promiseA));

        vm.selectFork(forkIds[1]);
        CrosschainSwapperB = new CrosschainSwapper{salt: bytes32(0)}(address(routerB), address(promiseB));

        // Verify same addresses
        require(
            address(CrosschainSwapperA) == address(CrosschainSwapperB),
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
        tokenIn.approve(address(CrosschainSwapperA), swapAmount);

        // Call initSwap to start the cross-chain swap
        console.log("Calling initSwap on Chain A");
        (bytes32 bridgePromiseId, bytes32 swapCallbackId, bytes32 bridgeBackCallbackId) = CrosschainSwapperA.initSwap(
            chainIdByForkId[forkIds[1]], // Destination chain (Chain B)
            address(tokenIn), // Token to swap from
            address(tokenOut), // Token to swap to
            swapAmount, // Amount to swap
            minAmountOut, // Minimum amount out
            user // Recipient
        );

        vm.stopPrank();

        console.log("initSwap completed:");
        console.log("  bridgePromiseId:", uint256(bridgePromiseId));
        console.log("  swapCallbackId:", uint256(swapCallbackId));
        console.log("  bridgeBackCallbackId:", uint256(bridgeBackCallbackId));
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
        // PHASE 3: CHAIN B - RESOLVE CALLBACK TO EXECUTE RELAYSWAP
        // ========================================
        console.log("PHASE 3: CHAIN B - RESOLVE CALLBACK TO EXECUTE RELAYSWAP");

        vm.selectFork(forkIds[1]);

        // Check if swap callback can be resolved
        if (CrosschainSwapperB.CALLBACK().canResolve(swapCallbackId)) {
            console.log("Resolving swap callback on Chain B");
            CrosschainSwapperB.CALLBACK().resolve(swapCallbackId);
            console.log("Swap callback resolved - relaySwap executed");
        } else {
            console.log("Swap callback not ready for resolution");
        }
        console.log("CrosschainSwapper balance", tokenOut.balanceOf(address(CrosschainSwapperB)));

        // ========================================
        // PHASE 4: CHAIN B - RESOLVE CALLBACK TO EXECUTE BRIDGEBACK
        // ========================================
        console.log("PHASE 4: CHAIN B - RESOLVE CALLBACK TO EXECUTE BRIDGEBACK");

        // Check if bridge back callback can be resolved
        if (CrosschainSwapperB.CALLBACK().canResolve(bridgeBackCallbackId)) {
            console.log("Resolving bridge back callback on Chain B");
            CrosschainSwapperB.CALLBACK().resolve(bridgeBackCallbackId);
            console.log("Bridge back callback resolved - bridgeBack executed");
        } else {
            console.log("Bridge back callback not ready for resolution");
        }
        console.log("");

        // ========================================
        // PHASE 5: RELAY MESSAGES
        // ========================================
        console.log("PHASE 5: RELAY MESSAGES");
        console.log("Relaying cross-chain messages from Chain B to Chain A");

        relayAllMessages();
        console.log("Final messages relayed successfully");

        // Process the bridge message on Chain A to mint tokens
        vm.selectFork(forkIds[0]);
        console.log("Processing bridge message on Chain A");
        relayAllMessages();
        console.log("");

        // ========================================
        // PHASE 6: VERIFICATION
        // ========================================
        console.log("PHASE 6: VERIFICATION");

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
}
