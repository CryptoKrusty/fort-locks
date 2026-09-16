// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title Uniswap V3 Position Manager Interface
/// @notice Minimal interface used by Fort to interact with the canonical
///         Uniswap V3 NonfungiblePositionManager on Ethereum mainnet.
interface IPositionManager {
    /// @notice Parameters used when collecting tokens owed by a Uniswap V3 position.
    /// @param tokenId Position NFT token ID.
    /// @param recipient Address that receives the collected tokens.
    /// @param amount0Max Maximum amount of token0 to collect.
    /// @param amount1Max Maximum amount of token1 to collect.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Data returned for a Uniswap V3 liquidity position.
    /// @dev Field order and types must match the canonical PositionManager positions() return values.
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the data for a Uniswap V3 position NFT.
    /// @param tokenId Position NFT token ID.
    /// @return position Position data returned by the PositionManager.
    function positions(uint256 tokenId) external view returns (Position memory position);

    /// @notice Collects tokens owed by a Uniswap V3 position.
    /// @param params Collection parameters.
    /// @return amount0 Amount of token0 collected.
    /// @return amount1 Amount of token1 collected.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}
