// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "src/Promise.sol";
import {Callback} from "src/Callback.sol";
import {Relayer} from "src/test/Relayer.sol";
import {Test} from "forge-std/Test.sol";
import {MockSuperchainERC20} from "../examples/utils/MockSuperchainERC20.sol";
import {MockExchange} from "../examples/utils/MockExchange.sol";
import {ISuperchainTokenBridge} from "src/interfaces/ISuperchainTokenBridge.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Implementation of a test scenario where a user swaps tokens on chain A, bridges them to chain B, and then swaps them back on chain B.
contract SwapThenBridgeTest is Relayer, Test {
    // Address of the L2ToL2CrossDomainMessenger predeploy.
    address internal constant L2_TO_L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000023;

    // Address of the SuperchainTokenBridge predeploy.
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    address internal user;
    address internal liquidityProvider;

    // Contracts to deploy on both chains
    Promise public promiseA;
    Promise public promiseB;

    Callback public callbackA;
    Callback public callbackB;

    MockSuperchainERC20 public token1;
    MockSuperchainERC20 public token2;

    MockExchange public exchangeA;
    MockExchange public exchangeB;

    // This only lives in chain A
    CallbackHandler public callbackHandler;

    uint256 public initialToken1BalanceA;
    uint256 public initialToken2BalanceA;

    constructor() Relayer(_rpcUrls()) {}

    function setUp() public {
        user = makeAddr("user");
        liquidityProvider = makeAddr("liquidityProvider");

        console2.log("Deploying promise system contracts on chain A");
        console2.log("==================================================");
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        callbackA = new Callback{salt: bytes32(0)}(address(promiseA), L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        exchangeA = new MockExchange{salt: bytes32(0)}();
        callbackHandler = new CallbackHandler{salt: bytes32(0)}(
            promiseA, exchangeA, ISuperchainTokenBridge(SUPERCHAIN_TOKEN_BRIDGE), user
        );

        console2.log("Deploying promise system contracts on chain B");
        console2.log("==================================================");
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        callbackB = new Callback{salt: bytes32(0)}(address(promiseB), L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        exchangeB = new MockExchange{salt: bytes32(0)}();
        CallbackHandler callbackHandlerB = new CallbackHandler{salt: bytes32(0)}(
            promiseB, exchangeB, ISuperchainTokenBridge(SUPERCHAIN_TOKEN_BRIDGE), user
        );

        // Verify same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");

        console2.log("Deploying tokens on chain A");
        vm.selectFork(forkIds[0]);
        token1 = new MockSuperchainERC20{salt: bytes32(0)}("Token1", "TK1", 100_000 ether, SUPERCHAIN_TOKEN_BRIDGE);
        token2 = new MockSuperchainERC20{salt: bytes32(0)}("Token2", "TK2", 100_000 ether, SUPERCHAIN_TOKEN_BRIDGE);

        console2.log("Deploying tokens on chain B");
        console2.log("==================================================");
        vm.selectFork(forkIds[1]);
        MockSuperchainERC20 token1B =
            new MockSuperchainERC20{salt: bytes32(0)}("Token1", "TK1", 100_000 ether, SUPERCHAIN_TOKEN_BRIDGE);
        MockSuperchainERC20 token2B =
            new MockSuperchainERC20{salt: bytes32(0)}("Token2", "TK2", 100_000 ether, SUPERCHAIN_TOKEN_BRIDGE);

        vm.label(address(token1), "Token1");
        vm.label(address(token2), "Token2");

        // Verify same addresses
        require(address(token1) == address(token1B), "Token1 must have same address");
        require(address(token2) == address(token2B), "Token2 must have same address");

        // Set up initial token distribution and exchange liquidity
        setupTokensAndLiquidity();

        // Store initial balances
        vm.selectFork(forkIds[0]);
        initialToken1BalanceA = token1.balanceOf(user);
        initialToken2BalanceA = token2.balanceOf(user);
    }

    function test_SwapBridgeSwap_Success() public {
        vm.selectFork(forkIds[0]);

        // Swap token1 for token2 on chain A
        vm.startPrank(user);
        token1.transfer(address(callbackHandler), 1000 ether);

        // Create promise to swap tokens on chain A
        bytes32 promiseId = promiseA.create();
        bytes32 promiseId2 =
            callbackA.then(promiseId, address(callbackHandler), CallbackHandler.handleInitialSwap.selector);
        // Create promise to bridge tokens to chain B
        bytes32 promiseId3 = callbackA.then(promiseId2, address(callbackHandler), CallbackHandler.handleBridge.selector);

        promiseA.resolve(
            promiseId, abi.encode(chainIdByForkId[forkIds[1]], address(token1), address(token2), 1000 ether)
        );
        callbackA.resolve(promiseId2);

        token2.approve(address(callbackHandler), 1000 ether);
        callbackA.resolve(promiseId3);

        promiseA.shareResolvedPromise(chainIdByForkId[forkIds[1]], promiseId3);

        assertEq(token2.balanceOf(user), 1000 ether);

        bytes32 promiseId4 = callbackB.thenOn(
            chainIdByForkId[forkIds[1]], promiseId3, address(callbackHandler), CallbackHandler.handleSecondSwap.selector
        );

        vm.selectFork(forkIds[1]);
        relayAllMessages();

        token2.approve(address(callbackHandler), 1000 ether);

        callbackB.resolve(promiseId4);

        vm.stopPrank();
    }

    function _rpcUrls() internal view returns (string[] memory rpcs_) {
        rpcs_ = new string[](2);
        rpcs_[0] = vm.rpcUrl("op_mainnet");
        rpcs_[1] = vm.rpcUrl("base");
        return rpcs_;
    }

    function setupTokensAndLiquidity() internal {
        console2.log("Setting up tokens and liquidity");
        console2.log("==================================================");
        // Chain A setup
        vm.selectFork(forkIds[0]);

        // Transfer initial tokens from test contract (which has 100k of each token)
        token1.transfer(user, 1000 ether); // User starts with Token1 on Chain A
        token2.transfer(liquidityProvider, 20000 ether); // LP gets Token2 for liquidity
        token1.transfer(liquidityProvider, 10000 ether); // LP gets Token1 for liquidity

        // Setup Chain A exchange (for potential rollback scenarios)
        vm.startPrank(liquidityProvider);
        token1.approve(address(exchangeA), 5000 ether);
        token2.approve(address(exchangeA), 5000 ether);
        exchangeA.provideLiquidity(address(token1), 5000 ether);
        exchangeA.provideLiquidity(address(token2), 5000 ether);
        exchangeA.addPair(address(token1), address(token2), 10000); // 1:1 rate
        exchangeA.addPair(address(token2), address(token1), 10000); // Reverse pair
        vm.stopPrank();

        // Chain B setup
        vm.selectFork(forkIds[1]);

        // Transfer tokens for Chain B liquidity from test contract (which has 100k of each token)
        token1.transfer(liquidityProvider, 10000 ether); // LP gets Token1 for Chain B exchange
        token2.transfer(liquidityProvider, 10000 ether); // LP gets Token2 for Chain B exchange

        // Setup Chain B exchange (Token1 <-> Token2) - this is where the main swap happens
        vm.startPrank(liquidityProvider);
        token1.approve(address(exchangeB), 5000 ether);
        token2.approve(address(exchangeB), 5000 ether);
        exchangeB.provideLiquidity(address(token1), 5000 ether);
        exchangeB.provideLiquidity(address(token2), 5000 ether);
        exchangeB.addPair(address(token1), address(token2), 10000); // 1:1 rate
        exchangeB.addPair(address(token2), address(token1), 10000); // Reverse pair for rollback
        vm.stopPrank();

        console2.log("Tokens and liquidity setup complete");
        console2.log("==================================================");
    }
}

/// @notice An intermediary contract that can be used to execute a swap on behalf of a user
///         for a promise based setup. The contract can hold the tokens and handle authorization concerns.
contract CallbackHandler {
    Promise public promiseContract;
    address public user;
    MockExchange public exchange;
    ISuperchainTokenBridge public superchainTokenBridge;

    constructor(
        Promise _promiseContract,
        MockExchange _exchange,
        ISuperchainTokenBridge _superchainTokenBridge,
        address _user
    ) {
        promiseContract = _promiseContract;
        user = _user;
        exchange = _exchange;
        superchainTokenBridge = _superchainTokenBridge;
    }

    function handleInitialSwap(bytes memory _data)
        public
        returns (uint256 chainId_, address fromToken_, address destToken_, uint256 amount_)
    {
        (uint256 destinationId, address tokenIn, address tokenOut, uint256 amountIn) =
            abi.decode(_data, (uint256, address, address, uint256));
        console2.log("Handling initial swap");
        console2.log("==================================================");
        console2.log("Token in: ", tokenIn);
        console2.log("Token out: ", tokenOut);
        console2.log("Amount in: ", amountIn);

        MockSuperchainERC20(tokenIn).approve(address(exchange), amountIn);
        uint256 amountOut = exchange.swap(tokenIn, tokenOut, amountIn);

        console2.log("Amount out: ", amountOut);

        MockSuperchainERC20(tokenOut).transfer(user, amountOut);

        chainId_ = destinationId;
        fromToken_ = tokenIn;
        destToken_ = tokenOut;
        amount_ = amountOut;
    }

    function handleSecondSwap(address tokenIn, address tokenOut, uint256 amountIn)
        public
        returns (uint256 amountOut_)
    {
        console2.log("Handling second swap");
        console2.log("==================================================");
        console2.log("Token in: ", tokenIn);
        console2.log("Token out: ", tokenOut);
        console2.log("Amount in: ", amountIn);

        MockSuperchainERC20(tokenIn).transferFrom(user, address(this), amountIn);
        MockSuperchainERC20(tokenIn).approve(address(exchange), amountIn);
        amountOut_ = exchange.swap(tokenIn, tokenOut, amountIn);

        console2.log("Amount out: ", amountOut_);
    }

    function handleBridge(uint256 destinationId, address bridgeToken, address otherToken, uint256 amount)
        public
        returns (address tokenIn_, address tokenOut_, uint256 amount_)
    {
        console2.log("Handling bridge");
        console2.log("==================================================");
        console2.log("Bridge token: ", bridgeToken);
        console2.log("Other token: ", otherToken);
        console2.log("Amount: ", amount);

        MockSuperchainERC20(bridgeToken).transferFrom(user, address(this), amount);

        superchainTokenBridge.sendERC20(bridgeToken, user, amount, destinationId);

        tokenIn_ = bridgeToken;
        tokenOut_ = otherToken;
        amount_ = amount;
    }
}
