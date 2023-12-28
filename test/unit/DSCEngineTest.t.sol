//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    //////////////////
    //    Events    //
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////
    //   Constructor Tests    //
    ////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////////
    //    Price Feed Tests    //
    ////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * $2000/ETH = 30,000e18
        uint256 expectedUsdValue = 30_000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether; // acktually $100
        // assume $2000/ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////////
    //    depositCollateral Tests    //
    ////////////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenCollateralOtherThanExpected.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testEmitsAfterDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralDeposited(USER, address(weth), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////////
    //     redeemCollateral Tests     //
    ////////////////////////////////////

    function testRedeemCollateral() public depositedCollateral {
        uint256 userBalanceBeforeRedeem = ERC20Mock(weth).balanceOf(USER);
        console.log(userBalanceBeforeRedeem);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL); //ERROR HERE
        uint256 userBalanceAfterRedeem = ERC20Mock(weth).balanceOf(USER);
        console.log(userBalanceAfterRedeem, userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        assert((userBalanceAfterRedeem - userBalanceBeforeRedeem) == AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsWhenRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWhenRedeemAmountTooMuch() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    ////////////////////////////////////
    //         mintDsc Tests          //
    ////////////////////////////////////

    function testMintDscWorksToMintFiftyPercent() public depositedCollateral {
        vm.startPrank(USER);
        uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedDscMinted = collateralValueInUsd / 2;
        engine.mintDsc(expectedDscMinted);
        uint256 actualDscMinted = dsc.balanceOf(USER);
        vm.stopPrank();
        assertEq(expectedDscMinted, actualDscMinted);
    }

    function testMintDscRevertsWhenMintingSixtyPercent() public depositedCollateral {
        vm.startPrank(USER);
        uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 dscToBeMinted = collateralValueInUsd * 6 / 10;
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorBroken.selector);
        engine.mintDsc(dscToBeMinted);
        vm.stopPrank();
    }

    ////////////////////////////////////
    //         burnDsc Tests          //
    ////////////////////////////////////

    function testBurnDsc() public depositedCollateral {
        vm.startPrank(USER);
        uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 dscToBeMinted = collateralValueInUsd / 2;
        engine.mintDsc(dscToBeMinted);
        uint256 actualDscMinted = dsc.balanceOf(USER);
        console.log("Actual Dsc Minted:", actualDscMinted);
        dsc.approve(address(engine), dscToBeMinted);
        engine.burnDsc(dscToBeMinted);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testRevertsWhenBurningTooMuch() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_TO_MINT);
        uint256 amountToBurn = AMOUNT_TO_MINT + 1;
        dsc.approve(address(engine), amountToBurn);

        vm.expectRevert();
        engine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testRevertsIfBurningZero() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    ////////////////////////////////////
    //        Liquidate Tests         //
    ////////////////////////////////////
    function testRevertsIfLiquidatingZero() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorNotViolated() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_TO_MINT / 2);
        dsc.approve(address(engine), (AMOUNT_TO_MINT / 2));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotViolated.selector);
        engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }
}
