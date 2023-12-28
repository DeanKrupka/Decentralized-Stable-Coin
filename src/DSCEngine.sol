//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Dean Krupka
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * This stablecoin has the following properties:
 * - Exogenous Collateral
 * - Dollar Peg
 * - Algorithmic Stability
 *
 * It is similar to DAI, but if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * DSC system should always be overcollateralized. At no point should the value of the collateral dip below the value of DSC.
 *
 * @notice This contract handles all the logic for minting and redeeming DSC as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 *
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////
    //    Errors    //
    //////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAndPriceFeedLengthMismatch();
    error DSCEngine__TokenCollateralOtherThanExpected();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken();
    error DSCEngine__MintDscFailed();
    error DSCEngine__HealthFactorNotViolated();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////
    //     Type     //
    //////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////////
    //    State Variables    //
    ///////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidating

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //userToTokenToAmount
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; //userToAmountDscMinted
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    //    Events    //
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    //////////////////
    //   Modifiers  //
    //////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenCollateralOtherThanExpected();
        }
        _;
    }

    //////////////////
    //  Functions   //
    //////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress //* DecentralizedStableCoin.sol *//
    ) {
        // Initialize state variables using @param tokenAddresses and @param priceFeedAddresses
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        // Initialize state variables: DSC Contract @param dscAddress
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //*/////////////////////////////////
    //*  Public / External Functions  //
    //*/////////////////////////////////

    /*
     * @param tokenCollateralAddress - The address of the collateral token to deposit
     * @param amountCollateral - The amount of collateral to deposit
     * @param amountDscToMint - The amount of DSC to mint
     * @notice deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress - The address of the collateral token to deposit
     * @param amountCollateral - The amount of collateral to deposit
     * @notice follow CEI (Checks, Effects, Interactins)
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param tokenCollateralAddress - The address of the collateral token to deposit
     * @param amountCollateral - The amount of collateral to deposit
     * @param amountDscToMint - The amount of DSC to mint
     * @notice follow CEI (Checks, Effects, Interactins) 
     * @notie redeem and burn in one tx
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral checks Health Factor and reverts if broken
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param amountDscToMint - The amount of DSC to mint
     * @notice Caller must have more collateral than minimum threshold
     * @notice follow CEI 
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintDscFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // Likely will NEVER be hit
    }

    /*
     * @param collateral - The erc20 collateral address to liquidate from the user
     * @param user - LIQUIDATE THEM
     * @param debtToCover - The amount of DSC to burn in order to imporve USER'S health factor
     * @notice you can partially liquidate a user
     * @notice you get a liquidation bonus for calling this function (10%)
     * @notice Assumes protocol is 200% overcollateralized (if collateral enmasse gets rekt, well, this shit wont work)
     * @notice function allows users to liq other users if their health factor dips below 1
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotViolated();
        }
        // This next line answers the Question, "How much WETH can I take now that I'm burning DSC debt?"
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //We are giving the liquidator a 10% bonus on top of the DSC value they burned (but all measured in WETH)
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //*////////////////////////////////////
    //*  Private and Internal Functions  //
    //*////////////////////////////////////

    /*
     * @dev Low-level internal function, Do not call unless the function 
     * calling it is checking for health factors being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        private
        moreThanZero(amountDscToBurn)
    {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return MIN_HEALTH_FACTOR * 2;
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // Same as dividing by 2
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /*
     * @param user - The address of the user to check
     * @notice follow CEI 
     * @notice Returns how close to liquidation the user is
     * IF A USER GOES BELOW 1, THEN THEY CAN BET LIQUIDATED
     */

    // function _healthFactor(address user) private view returns (uint256) {
    //     (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    //     uint256 collateralAdjustedForTheshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; //Same as dividing by 2
    //     return (collateralAdjustedForTheshold * PRECISION) / totalDscMinted;
    // }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        // Check if totalDscMinted is zero before performing division
        if (totalDscMinted == 0) {
            // Handle the division by zero case
            return MIN_HEALTH_FACTOR * 2;
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // Same as dividing by 2
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //1. Check health factor ("Does User have enough collateral?")
    //2. If health factor is broken, revert ("Nah, you broke broke")
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken();
        }
    }

    //*////////////////////////////////////////
    //*  Public and External View Functions  //
    //*////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Get price of WETH from priceFeed
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 2000 USD
        // The returned value from chainlink will be 2000 * 1e8
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token user has depositerd, get totals
        // get price from price feeds
        // multiply and total

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // price is in 8 decimals
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
