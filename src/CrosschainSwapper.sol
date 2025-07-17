// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PromiseLib} from "./libraries/PromiseLib.sol";
import {PromiseCallback} from "./PromiseCallback.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {ISuperchainTokenBridge} from "./interfaces/ISuperchainTokenBridge.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ISuperchainERC20} from "./interfaces/ISuperchainERC20.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {IPromiseCallback} from "./interfaces/IPromiseCallback.sol";

contract CrosschainSwapper {
    using PromiseLib for IPromiseCallback;

    error CrosschainSwapper__SwapFailed(address tokenIn, uint256 amountIn, address recipient, uint256 destinationId);
    error CrosschainSwapper__InvalidCreator();
    error CrosschainSwapper__InvalidCallback();
    error CrosschainSwapper__ZeroAddress();

    event PromiseDataRegistered(bytes32 promiseData);
    event SuccessBridgeBack();

    ISuperchainTokenBridge constant SUPERCHAIN_TOKEN_BRIDGE =
        ISuperchainTokenBridge(PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE);

    IL2ToL2CrossDomainMessenger constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    IPromiseCallback public immutable PROMISE_CALLBACK;
    address public immutable ROUTER;
    IValidator public immutable VALIDATOR;

    constructor(address _promiseCallback, address _router, address _validator) {
        if (_router == address(0)) revert CrosschainSwapper__ZeroAddress();
        if (_promiseCallback == address(0)) revert CrosschainSwapper__ZeroAddress();
        if (_validator == address(0)) revert CrosschainSwapper__ZeroAddress();

        PROMISE_CALLBACK = IPromiseCallback(_promiseCallback);
        ROUTER = _router;
        VALIDATOR = IValidator(_validator);
    }

    modifier onlyPromiseCallback() {
        if (msg.sender != address(PROMISE_CALLBACK)) revert CrosschainSwapper__InvalidCallback();
        (address creator,) = PROMISE_CALLBACK.executionContext();
        if (creator != address(this)) revert CrosschainSwapper__InvalidCreator();
        _;
    }

    /// @notice Initialize a cross-chain swap
    /// @param destinationId The destination chain ID
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param amountIn The amount of input tokens to swap
    /// @param minAmountOut The minimum amount of output tokens required
    /// @param recipient The recipient address on the destination chain
    function initSwap(
        uint256 destinationId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        returns (bytes32 bridgeId, bytes32 bridgeBackId, bytes32 bridgeBackOnErrorId, bytes32 afterBridgeBackId)
    {
        // transfer tokens from user to this contract
        ISuperchainERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Send tokens to destination chain
        bytes32[] memory msgHashes = new bytes32[](1);
        msgHashes[0] = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(tokenIn, address(this), amountIn, destinationId);

        // Create promise for bridge to destination chain
        bridgeId = PROMISE_CALLBACK.createAutoOn(
            destinationId,
            address(this),
            abi.encodeCall(this.relaySwap, (tokenIn, tokenOut, amountIn, minAmountOut, recipient, block.chainid)),
            VALIDATOR,
            abi.encode(msgHashes)
        );

        // Attach then to bridge promise
        bridgeBackId = PROMISE_CALLBACK.thenOn(bridgeId, destinationId, address(this), this.bridgeBack.selector);
        // Attach catch to bridge promise
        bridgeBackOnErrorId = PROMISE_CALLBACK.catchErrorOn(
            bridgeId,
            destinationId,
            address(this),
            abi.encodeCall(this.bridgeBack, abi.encode(tokenIn, amountIn, recipient, block.chainid))
        );

        afterBridgeBackId = PROMISE_CALLBACK.then(
            bridgeBackId, address(this), abi.encodeCall(this.successBridgeBack, ()), VALIDATOR, bytes("")
        );
    }

    /// @notice Relay a swap in the destination chain
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param amountIn The amount of input tokens to swap
    /// @param minAmountOut The minimum amount of output tokens required
    /// @param recipient The recipient address on the destination chain
    /// @param destinationId The destination chain ID
    function relaySwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 destinationId
    )
        external
        onlyPromiseCallback
        returns (address finalToken, uint256 finalAmount, address finalRecipient, uint256 finalDestinationId)
    {
        // Approve tokens for MockExchange
        ISuperchainERC20(tokenIn).approve(ROUTER, amountIn);

        // Execute swap on MockExchange
        (bool success, bytes memory returnData) =
            ROUTER.call(abi.encodeWithSignature("swap(address,address,uint256)", tokenIn, tokenOut, amountIn));

        if (!success) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipient, destinationId);
        }

        // Decode swap results - MockExchange returns uint256 amountOut
        uint256 amountOut = abi.decode(returnData, (uint256));

        // Verify minimum amount out
        if (amountOut < minAmountOut) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipient, destinationId);
        }

        return (tokenOut, amountOut, recipient, destinationId);
    }

    /// @notice Bridge tokens back after successful swap (accepts encoded data)
    /// @param data Encoded bridge parameters from relaySwap
    /// @return msgHashes The encoded CDM message hashes
    function bridgeBack(bytes memory data) external onlyPromiseCallback returns (bytes32[] memory msgHashes) {
        (address token, uint256 amountOut, address recipient, uint256 destinationId) =
            abi.decode(data, (address, uint256, address, uint256));

        // Bridge the swapped tokens back to original chain
        msgHashes = new bytes32[](1);
        msgHashes[0] = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(token, recipient, amountOut, destinationId);
    }

    /// @notice Callback function to emit event when bridge back is successful
    function successBridgeBack() external onlyPromiseCallback {
        emit SuccessBridgeBack();
    }
}
