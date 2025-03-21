// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICoin} from "./interfaces/ICoin.sol";
import {ICoinComments} from "./interfaces/ICoinComments.sol";
import {IERC7572} from "./interfaces/IERC7572.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IProtocolRewards} from "./interfaces/IProtocolRewards.sol";
import {IWETH} from "./interfaces/IWETH.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContractVersionBase} from "./version/ContractVersionBase.sol";
import {CoinConstants} from "./utils/CoinConstants.sol";
import {MultiOwnable} from "./utils/MultiOwnable.sol";
import {TickMath} from "./utils/TickMath.sol";

/*
     $$$$$$\   $$$$$$\  $$$$$$\ $$\   $$\ 
    $$  __$$\ $$  __$$\ \_$$  _|$$$\  $$ |
    $$ /  \__|$$ /  $$ |  $$ |  $$$$\ $$ |
    $$ |      $$ |  $$ |  $$ |  $$ $$\$$ |
    $$ |      $$ |  $$ |  $$ |  $$ \$$$$ |
    $$ |  $$\ $$ |  $$ |  $$ |  $$ |\$$$ |
    \$$$$$$  | $$$$$$  |$$$$$$\ $$ | \$$ |
     \______/  \______/ \______|\__|  \__|
*/
contract Coin is ICoin, CoinConstants, ContractVersionBase, ERC20PermitUpgradeable, MultiOwnable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    address public immutable WETH;
    address public immutable nonfungiblePositionManager;
    address public immutable swapRouter;
    address public immutable protocolRewards;
    address public immutable protocolRewardRecipient;

    address public payoutRecipient;
    address public platformReferrer;
    address public poolAddress;
    address public currency;
    uint256 public lpTokenId;
    string public tokenURI;

    constructor(
        address _protocolRewardRecipient,
        address _protocolRewards,
        address _weth,
        address _nonfungiblePositionManager,
        address _swapRouter
    ) initializer {
        if (_protocolRewardRecipient == address(0)) {
            revert AddressZero();
        }
        if (_protocolRewards == address(0)) {
            revert AddressZero();
        }
        if (_weth == address(0)) {
            revert AddressZero();
        }
        if (_nonfungiblePositionManager == address(0)) {
            revert AddressZero();
        }
        if (_swapRouter == address(0)) {
            revert AddressZero();
        }

        protocolRewardRecipient = _protocolRewardRecipient;
        protocolRewards = _protocolRewards;
        WETH = _weth;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
    }

    /// @notice Initializes a new coin
    /// @param payoutRecipient_ The address of the coin creator
    /// @param tokenURI_ The metadata URI
    /// @param name_ The coin name
    /// @param symbol_ The coin symbol
    /// @param platformReferrer_ The address of the platform referrer
    /// @param currency_ The address of the currency
    /// @param tickLower_ The tick lower for the Uniswap V3 pool; ignored for ETH/WETH
    function initialize(
        address payoutRecipient_,
        address[] memory owners_,
        string memory tokenURI_,
        string memory name_,
        string memory symbol_,
        address platformReferrer_,
        address currency_,
        int24 tickLower_
    ) public initializer {
        // Validate the creation parameters
        if (payoutRecipient_ == address(0)) {
            revert AddressZero();
        }

        // Set base contract state
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __MultiOwnable_init(owners_);
        __ReentrancyGuard_init();

        // Set mutable state
        _setPayoutRecipient(payoutRecipient_);
        _setContractURI(tokenURI_);

        // Set immutable state
        platformReferrer = platformReferrer_ == address(0) ? protocolRewardRecipient : platformReferrer_;
        currency = currency_ == address(0) ? WETH : currency_;

        // Mint the total supply
        _mint(address(this), MAX_TOTAL_SUPPLY);

        // Distribute the creator launch reward
        _transfer(address(this), payoutRecipient, CREATOR_LAUNCH_REWARD);

        // Approve the transfer of the remaining supply to the pool
        IERC20(address(this)).safeIncreaseAllowance(address(nonfungiblePositionManager), POOL_LAUNCH_SUPPLY);

        // Deploy the pool
        _deployPool(tickLower_);
    }

    /// @notice Executes a buy order
    /// @param recipient The recipient address of the coins
    /// @param orderSize The amount of coins to buy
    /// @param tradeReferrer The address of the trade referrer
    /// @param sqrtPriceLimitX96 The price limit for Uniswap V3 pool swap
    function buy(
        address recipient,
        uint256 orderSize,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        address tradeReferrer
    ) public payable nonReentrant returns (uint256, uint256) {
        // Ensure the recipient is not the zero address
        if (recipient == address(0)) {
            revert AddressZero();
        }

        // Calculate the trade reward
        uint256 tradeReward = _calculateReward(orderSize, TOTAL_FEE_BPS);

        // Calculate the remaining size
        uint256 trueOrderSize = orderSize - tradeReward;

        // Handle incoming currency
        _handleIncomingCurrency(orderSize, trueOrderSize);

        // Set up the swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: currency,
            tokenOut: address(this),
            fee: LP_FEE,
            recipient: recipient,
            amountIn: trueOrderSize,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Execute the swap
        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        _handleTradeRewards(tradeReward, tradeReferrer);

        _handleMarketRewards();

        emit CoinBuy(msg.sender, recipient, tradeReferrer, amountOut, currency, tradeReward, trueOrderSize);

        return (orderSize, amountOut);
    }

    /// @notice Executes a sell order
    /// @param recipient The recipient of the currency
    /// @param orderSize The amount of coins to sell
    /// @param minAmountOut The minimum amount of currency to receive
    /// @param sqrtPriceLimitX96 The price limit for the swap
    /// @param tradeReferrer The address of the trade referrer
    function sell(
        address recipient,
        uint256 orderSize,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        address tradeReferrer
    ) public nonReentrant returns (uint256, uint256) {
        // Ensure the recipient is not the zero address
        if (recipient == address(0)) {
            revert AddressZero();
        }

        // Record the coin balance of this contract before the swap
        uint256 beforeCoinBalance = balanceOf(address(this));

        // Transfer the coins from the seller to this contract
        transfer(address(this), orderSize);

        // Approve the Uniswap V3 swap router
        this.approve(swapRouter, orderSize);

        // Set the swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(this),
            tokenOut: currency,
            fee: LP_FEE,
            recipient: address(this),
            amountIn: orderSize,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Execute the swap
        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        // Record the coin balance of this contract after the swap
        uint256 afterCoinBalance = balanceOf(address(this));

        // If the swap was partially executed:
        if (afterCoinBalance > beforeCoinBalance) {
            // Calculate the refund
            uint256 coinRefund = afterCoinBalance - beforeCoinBalance;

            // Update the order size
            orderSize -= coinRefund;

            // Transfer the refund back to the seller
            _transfer(address(this), recipient, coinRefund);
        }

        // If currency is WETH, convert to ETH
        if (currency == WETH) {
            IWETH(WETH).withdraw(amountOut);
        }

        // Calculate the trade reward
        uint256 tradeReward = _calculateReward(amountOut, TOTAL_FEE_BPS);

        // Calculate the payout after the fee
        uint256 payoutSize = amountOut - tradeReward;

        _handlePayout(payoutSize, recipient);

        _handleTradeRewards(tradeReward, tradeReferrer);

        _handleMarketRewards();

        emit CoinSell(msg.sender, recipient, tradeReferrer, orderSize, currency, tradeReward, payoutSize);

        return (orderSize, payoutSize);
    }

    /// @notice Enables a user to burn their tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Force claim any accrued secondary rewards from the market's liquidity position.
    /// @dev This function is a fallback, secondary rewards will be claimed automatically on each buy and sell.
    /// @param pushEthRewards Whether to push the ETH directly to the recipients.
    function claimSecondaryRewards(bool pushEthRewards) external nonReentrant {
        MarketRewards memory rewards = _handleMarketRewards();

        if (pushEthRewards && rewards.totalAmountCurrency > 0 && currency == WETH) {
            IProtocolRewards(protocolRewards).withdrawFor(payoutRecipient, rewards.creatorPayoutAmountCurrency);
            IProtocolRewards(protocolRewards).withdrawFor(platformReferrer, rewards.platformReferrerAmountCurrency);
            IProtocolRewards(protocolRewards).withdrawFor(protocolRewardRecipient, rewards.protocolAmountCurrency);
        }
    }

    /// @notice Set the creator's payout address
    /// @param newPayoutRecipient The new recipient address
    function setPayoutRecipient(address newPayoutRecipient) external onlyOwner {
        _setPayoutRecipient(newPayoutRecipient);
    }

    /// @notice Set the contract URI
    /// @param newURI The new URI
    function setContractURI(string memory newURI) external onlyOwner {
        _setContractURI(newURI);
    }

    /// @notice The contract metadata
    function contractURI() external view returns (string memory) {
        return tokenURI;
    }

    /// @notice ERC165 interface support
    /// @param interfaceId The interface ID to check
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return
            interfaceId == type(ICoin).interfaceId ||
            interfaceId == type(ICoinComments).interfaceId ||
            interfaceId == type(IERC7572).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Receives ETH converted from WETH
    receive() external payable {
        if (msg.sender != WETH) {
            revert OnlyWeth();
        }
    }

    /// @dev For receiving the Uniswap V3 LP NFT on market graduation.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != poolAddress) revert OnlyPool();

        return this.onERC721Received.selector;
    }

    /// @dev No-op to allow a swap on the pool to set the correct initial price, if needed
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {}

    /// @dev Overrides ERC20's _update function to
    ///      - Prevent transfers to the pool if the market has not graduated.
    ///      - Emit the superset `WowTokenTransfer` event with each ERC20 transfer.
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        emit CoinTransfer(from, to, value, balanceOf(from), balanceOf(to));
    }

    /// @dev Used to set the payout recipient on coin creation and updates
    /// @param newPayoutRecipient The new recipient address
    function _setPayoutRecipient(address newPayoutRecipient) internal {
        if (newPayoutRecipient == address(0)) {
            revert AddressZero();
        }

        emit CoinPayoutRecipientUpdated(msg.sender, payoutRecipient, newPayoutRecipient);

        payoutRecipient = newPayoutRecipient;
    }

    /// @dev Used to set the contract URI on coin creation and updates
    /// @param newURI The new URI
    function _setContractURI(string memory newURI) internal {
        emit ContractMetadataUpdated(msg.sender, newURI, name());
        emit ContractURIUpdated();

        tokenURI = newURI;
    }

    /// @dev Deploy the pool
    function _deployPool(int24 tickLower_) internal {
        // If WETH is the pool's currency, validate the lower tick
        if (currency == WETH && tickLower_ < LP_TICK_LOWER_WETH) {
            revert InvalidWethLowerTick();
        }

        // Note: This validation happens on the Uniswap pool already; reverting early here for clarity
        // If currency is not WETH: ensure lower tick is less than upper tick and satisfies the 200 tick spacing requirement for 1% Uniswap V3 pools
        if (currency != WETH && (tickLower_ >= LP_TICK_UPPER || tickLower_ % 200 != 0)) {
            revert InvalidCurrencyLowerTick();
        }

        // Sort the token addresses
        address token0 = address(this) < currency ? address(this) : currency;
        address token1 = address(this) < currency ? currency : address(this);

        // If the coin is token0
        bool isCoinToken0 = token0 == address(this);

        // Determine the tick values
        int24 tickLower = isCoinToken0 ? tickLower_ : -LP_TICK_UPPER;
        int24 tickUpper = isCoinToken0 ? LP_TICK_UPPER : -tickLower_;

        // Calculate the starting price for the pool
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(isCoinToken0 ? tickLower : tickUpper);

        // Determine the initial liquidity amounts
        uint256 amount0 = isCoinToken0 ? POOL_LAUNCH_SUPPLY : 0;
        uint256 amount1 = isCoinToken0 ? 0 : POOL_LAUNCH_SUPPLY;

        // Create and initialize the pool
        poolAddress = INonfungiblePositionManager(nonfungiblePositionManager).createAndInitializePoolIfNecessary(token0, token1, LP_FEE, sqrtPriceX96);

        // Construct the LP data
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: LP_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Mint the LP
        (lpTokenId, , , ) = INonfungiblePositionManager(nonfungiblePositionManager).mint(params);
    }

    /// @dev Handles incoming currency transfers for buy orders; if WETH is the currency the caller has the option to send native-ETH
    /// @param orderSize The total size of the order in the currency
    /// @param trueOrderSize The actual amount being used for the swap after fees
    function _handleIncomingCurrency(uint256 orderSize, uint256 trueOrderSize) internal {
        if (currency == WETH && msg.value > 0) {
            if (msg.value != orderSize) {
                revert EthAmountMismatch();
            }

            if (msg.value < MIN_ORDER_SIZE) {
                revert EthAmountTooSmall();
            }

            IWETH(WETH).deposit{value: trueOrderSize}();
            IWETH(WETH).approve(swapRouter, trueOrderSize);
        } else {
            // Ensure ETH is not sent with a non-ETH pair
            if (msg.value != 0) {
                revert EthTransferInvalid();
            }

            uint256 beforeBalance = IERC20(currency).balanceOf(address(this));
            IERC20(currency).safeTransferFrom(msg.sender, address(this), orderSize);
            uint256 afterBalance = IERC20(currency).balanceOf(address(this));

            if ((afterBalance - beforeBalance) != orderSize) {
                revert ERC20TransferAmountMismatch();
            }

            IERC20(currency).approve(swapRouter, trueOrderSize);
        }
    }

    /// @dev Handles sending ETH and ERC20 payouts and refunds to recipients
    /// @param orderPayout The amount of currency to pay out
    /// @param recipient The address to receive the payout
    function _handlePayout(uint256 orderPayout, address recipient) internal {
        if (currency == WETH) {
            Address.sendValue(payable(recipient), orderPayout);
        } else {
            IERC20(currency).safeTransfer(recipient, orderPayout);
        }
    }

    /// @dev Handles calculating and depositing fees to an escrow protocol rewards contract
    function _handleTradeRewards(uint256 totalValue, address _tradeReferrer) internal {
        if (_tradeReferrer == address(0)) {
            _tradeReferrer = protocolRewardRecipient;
        }

        uint256 tokenCreatorFee = _calculateReward(totalValue, TOKEN_CREATOR_FEE_BPS);
        uint256 platformReferrerFee = _calculateReward(totalValue, PLATFORM_REFERRER_FEE_BPS);
        uint256 tradeReferrerFee = _calculateReward(totalValue, TRADE_REFERRER_FEE_BPS);
        uint256 protocolFee = totalValue - tokenCreatorFee - platformReferrerFee - tradeReferrerFee;

        if (currency == WETH) {
            address[] memory recipients = new address[](4);
            uint256[] memory amounts = new uint256[](4);
            bytes4[] memory reasons = new bytes4[](4);

            recipients[0] = payoutRecipient;
            amounts[0] = tokenCreatorFee;
            reasons[0] = bytes4(keccak256("COIN_CREATOR_REWARD"));

            recipients[1] = platformReferrer;
            amounts[1] = platformReferrerFee;
            reasons[1] = bytes4(keccak256("COIN_PLATFORM_REFERRER_REWARD"));

            recipients[2] = _tradeReferrer;
            amounts[2] = tradeReferrerFee;
            reasons[2] = bytes4(keccak256("COIN_TRADE_REFERRER_REWARD"));

            recipients[3] = protocolRewardRecipient;
            amounts[3] = protocolFee;
            reasons[3] = bytes4(keccak256("COIN_PROTOCOL_REWARD"));

            IProtocolRewards(protocolRewards).depositBatch{value: totalValue}(recipients, amounts, reasons, "");
        }

        if (currency != WETH) {
            IERC20(currency).safeTransfer(payoutRecipient, tokenCreatorFee);
            IERC20(currency).safeTransfer(platformReferrer, platformReferrerFee);
            IERC20(currency).safeTransfer(_tradeReferrer, tradeReferrerFee);
            IERC20(currency).safeTransfer(protocolRewardRecipient, protocolFee);
        }

        emit CoinTradeRewards(
            payoutRecipient,
            platformReferrer,
            _tradeReferrer,
            protocolRewardRecipient,
            tokenCreatorFee,
            platformReferrerFee,
            tradeReferrerFee,
            protocolFee,
            currency
        );
    }

    function _handleMarketRewards() internal returns (MarketRewards memory) {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: lpTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 totalAmountToken0, uint256 totalAmountToken1) = INonfungiblePositionManager(nonfungiblePositionManager).collect(params);

        address token0 = currency < address(this) ? currency : address(this);
        address token1 = currency < address(this) ? address(this) : currency;

        MarketRewards memory rewards;

        rewards = _transferMarketRewards(token0, totalAmountToken0, rewards);
        rewards = _transferMarketRewards(token1, totalAmountToken1, rewards);

        emit CoinMarketRewards(payoutRecipient, platformReferrer, protocolRewardRecipient, currency, rewards);

        return rewards;
    }

    function _transferMarketRewards(address token, uint256 totalAmount, MarketRewards memory rewards) internal returns (MarketRewards memory) {
        if (totalAmount > 0) {
            uint256 creatorPayout = _calculateReward(totalAmount, CREATOR_MARKET_REWARD_BPS);
            uint256 platformReferrerPayout = _calculateReward(totalAmount, PLATFORM_REFERRER_MARKET_REWARD_BPS);
            uint256 protocolPayout = totalAmount - creatorPayout - platformReferrerPayout;

            if (token == WETH) {
                IWETH(WETH).withdraw(totalAmount);

                rewards.totalAmountCurrency = totalAmount;
                rewards.creatorPayoutAmountCurrency = creatorPayout;
                rewards.platformReferrerAmountCurrency = platformReferrerPayout;
                rewards.protocolAmountCurrency = protocolPayout;

                address[] memory recipients = new address[](3);
                recipients[0] = payoutRecipient;
                recipients[1] = platformReferrer;
                recipients[2] = protocolRewardRecipient;

                uint256[] memory amounts = new uint256[](3);
                amounts[0] = rewards.creatorPayoutAmountCurrency;
                amounts[1] = rewards.platformReferrerAmountCurrency;
                amounts[2] = rewards.protocolAmountCurrency;

                bytes4[] memory reasons = new bytes4[](3);
                reasons[0] = bytes4(keccak256("COIN_CREATOR_MARKET_REWARD"));
                reasons[1] = bytes4(keccak256("COIN_PLATFORM_REFERRER_MARKET_REWARD"));
                reasons[2] = bytes4(keccak256("COIN_PROTOCOL_MARKET_REWARD"));

                IProtocolRewards(protocolRewards).depositBatch{value: totalAmount}(recipients, amounts, reasons, "");
            } else if (token == address(this)) {
                rewards.totalAmountCoin = totalAmount;
                rewards.creatorPayoutAmountCoin = creatorPayout;
                rewards.platformReferrerAmountCoin = platformReferrerPayout;
                rewards.protocolAmountCoin = protocolPayout;

                _transfer(address(this), payoutRecipient, rewards.creatorPayoutAmountCoin);
                _transfer(address(this), platformReferrer, rewards.platformReferrerAmountCoin);
                _transfer(address(this), protocolRewardRecipient, rewards.protocolAmountCoin);
            } else {
                rewards.totalAmountCurrency = totalAmount;
                rewards.creatorPayoutAmountCurrency = creatorPayout;
                rewards.platformReferrerAmountCurrency = platformReferrerPayout;
                rewards.protocolAmountCurrency = protocolPayout;

                IERC20(currency).safeTransfer(payoutRecipient, creatorPayout);
                IERC20(currency).safeTransfer(platformReferrer, platformReferrerPayout);
                IERC20(currency).safeTransfer(protocolRewardRecipient, protocolPayout);
            }
        }

        return rewards;
    }

    /// @dev Utility for computing amounts in basis points.
    function _calculateReward(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }
}
