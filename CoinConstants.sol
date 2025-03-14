




// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

abstract contract CoinConstants {
    /// @notice The maximum total supply
    /// @dev Set to 1 billion coins with 18 decimals
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice The number of coins allocated to the liquidity pool
    /// @dev 990 million coins
    uint256 internal constant POOL_LAUNCH_SUPPLY = 990_000_000e18;

    /// @notice The number of coins rewarded to the creator
    /// @dev 10 million coins
    uint256 internal constant CREATOR_LAUNCH_REWARD = 10_000_000e18;

    /// @notice The minimum order size allowed for trades
    /// @dev Set to 0.0000001 ETH to prevent dust transactions
    uint256 public constant MIN_ORDER_SIZE = 0.0000001 ether;

    /// @notice The total fee percentage in basis points
    /// @dev 100 basis points = 1%
    uint256 public constant TOTAL_FEE_BPS = 100;

    /// @notice The percentage of the total fee allocated to creators
    /// @dev 5000 basis points = 50% of TOTAL_FEE_BPS
    uint256 public constant TOKEN_CREATOR_FEE_BPS = 5000;

    /// @notice The percentage of the total fee allocated to the protocol
    /// @dev 2000 basis points = 20% of TOTAL_FEE_BPS
    uint256 public constant PROTOCOL_FEE_BPS = 2000;

    /// @notice The percentage of the total fee allocated to platform referrers
    /// @dev 1500 basis points = 15% of TOTAL_FEE_BPS
    uint256 public constant PLATFORM_REFERRER_FEE_BPS = 1500;

    /// @notice The percentage of the total fee allocated to trade referrers
    /// @dev 1500 basis points = 15% of TOTAL_FEE_BPS
    uint256 public constant TRADE_REFERRER_FEE_BPS = 1500;

    /// @notice The percentage of the LP fee allocated to creators
    /// @dev 5000 basis points = 50% of LP_FEE
    uint256 internal constant CREATOR_MARKET_REWARD_BPS = 5000;

    /// @notice The percentage of the LP fee allocated to platform referrers
    /// @dev 2500 basis points = 25% of LP_FEE
    uint256 internal constant PLATFORM_REFERRER_MARKET_REWARD_BPS = 2500;

    /// @notice The LP fee
    /// @dev 10000 basis points = 1%
    uint24 internal constant LP_FEE = 10000;

    /// @notice The LP's minimum lower tick
    /// @dev This is only used if the currency is WETH
    int24 internal constant LP_TICK_LOWER_WETH = -208200;

    /// @notice The LP's upper tick
    int24 internal constant LP_TICK_UPPER = 887200;
}
