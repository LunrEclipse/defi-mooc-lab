//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external;
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
        //Everything needed for liquidation contract
        address AAVE_LENDING_POOL_ADDRESS = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
        //Collateral token
        address WRAPPED_BTC_ADDRESS = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        //Debt token
        address USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        address AAVE_BORROWER_ADDRESS = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
        uint256 AAVE_LIQUIDATION_DEBT_TO_COVER = 1749500000000;
        //2916378221684 - 24.121848004675783112 ETH
        //2416378221684 - 37.366978355771590511 ETH
        //2216378221684 - 40.649541985477976112 ETH
        //1916378221684 - 43.415443522344585477 ETH
        //1716378221684 - 43.821220519104933154 ETH
        //1750000000000 - 43.833442463190567285 ETH
        //1749500000000 - 43.833498824510530854 ETH
        //1516378221684 - 43.076711042891964395 ETH
        //
        // y = -1.4388*10^-23 + 5.0242*10^-11 - 0.0249769


        //Uniswap
        // address UNISWAP_V2_FACTORY_ADDRESS = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
        // address UNISWAP_V2_WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address UNISWAP_V2_WETH_USDT_PAIR_ADDRESS = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
        address UNISWAP_V2_WBTC_WETH_PAIR_ADDRESS = 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940;

        address WRAPPED_ETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        uint256 amountToRepay = 0;
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {
    }
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***


        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        (, uint256 totalDebt, , , , uint256 healthFactor ) = ILendingPool(AAVE_LENDING_POOL_ADDRESS).getUserAccountData(AAVE_BORROWER_ADDRESS);
        //AAVE_LIQUIDATION_DEBT_TO_COVER = totalDebt * 49 / 100;
        require(healthFactor < 1e18, "User is not liquidatable");


        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***

        //Get the amount of USDT to 
        //WETH - token0, USDT - token1
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS).getReserves();
        uint256 repayment = getAmountIn(AAVE_LIQUIDATION_DEBT_TO_COVER, reserve0, reserve1);
        amountToRepay = repayment;

        // uint256 amountToBorrow = getAmountOut(AAVE_LIQUIDATION_DEBT_TO_COVER, reserve0, reserve1);
        // IUniswapV2Pair(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS).swap(0, amountToBorrow, address(this), new bytes(1));
        IUniswapV2Pair(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS).swap(0, AAVE_LIQUIDATION_DEBT_TO_COVER, address(this), new bytes(1));
        IUniswapV2Pair(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS).swap(0, AAVE_LIQUIDATION_DEBT_TO_COVER, address(this), new bytes(1));
        


        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        IWETH(WRAPPED_ETH_ADDRESS).withdraw(IERC20(WRAPPED_ETH_ADDRESS).balanceOf(address(this)));
        payable(msg.sender).transfer(address(this).balance);

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        require(msg.sender == UNISWAP_V2_WETH_USDT_PAIR_ADDRESS, "Invalid caller");
        // (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS).getReserves();
        // uint256 amountToBorrow = getAmountOut(AAVE_LIQUIDATION_DEBT_TO_COVER, reserve0, reserve1);
        uint256 amountToBorrow = AAVE_LIQUIDATION_DEBT_TO_COVER;
        require(amount1 == amountToBorrow, "Invalid amount");
        require(IERC20(USDT_ADDRESS).balanceOf(address(this)) == amount1, "Invalid balance");

        // 2.1 liquidate the target user
        //    *** Your code here ***
        IERC20(USDT_ADDRESS).approve(AAVE_LENDING_POOL_ADDRESS, amountToBorrow);
        ILendingPool(AAVE_LENDING_POOL_ADDRESS).liquidationCall(
            WRAPPED_BTC_ADDRESS,
            USDT_ADDRESS,
            AAVE_BORROWER_ADDRESS,
            amount1,
            false
        );


        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        uint256 wbtcBalance = IERC20(WRAPPED_BTC_ADDRESS).balanceOf(address(this));
        require(wbtcBalance > 0, "Invalid WBTC balance");
        //WBTC - token0, WETH - token1
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(UNISWAP_V2_WBTC_WETH_PAIR_ADDRESS).getReserves();
        uint256 amountToSwap = getAmountOut(wbtcBalance, reserve0, reserve1);
        IERC20(WRAPPED_BTC_ADDRESS).transfer(UNISWAP_V2_WBTC_WETH_PAIR_ADDRESS, wbtcBalance);
        IUniswapV2Pair(UNISWAP_V2_WBTC_WETH_PAIR_ADDRESS).swap(0, amountToSwap, address(this), new bytes(0));

        // 2.3 repay
        //    *** Your code here ***
        uint256 wethBalance = IERC20(WRAPPED_ETH_ADDRESS).balanceOf(address(this));
        //(reserve0, reserve1, ) = IUniswapV2Pair(UNISWAP_V2_WBTC_WETH_PAIR_ADDRESS).getReserves();
        //uint256 amountToRepay = getAmountIn(AAVE_LIQUIDATION_DEBT_TO_COVER, reserve0, reserve1);
        require(wethBalance >= amountToRepay, "Invalid WETH balance");
        IERC20(WRAPPED_ETH_ADDRESS).transfer(UNISWAP_V2_WETH_USDT_PAIR_ADDRESS, amountToRepay);        
        // END TODO
    }
}
