// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FortLocks} from "../src/FortLocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH {
    function deposit() external payable;

    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPositionManagerTest {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}

contract FortLocksForkTest is Test {
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function test_CanonicalPositionManagerExistsOnMainnet() public view {
        assertGt(POSITION_MANAGER.code.length, 0);
    }

    function test_CustomPositionsInterfaceDecodesMainnetPosition() public view {
        uint256 tokenId = 1_224_792;

        IPositionManager.Position memory position = IPositionManager(POSITION_MANAGER).positions(tokenId);

        assertTrue(position.token0 != address(0));
        assertTrue(position.token1 != address(0));
        assertTrue(position.token0 != position.token1);
        assertGt(position.fee, 0);
    }

    function test_CustomInterfaceMatchesRawMainnetPosition() public view {
        uint256 tokenId = 1_224_792;

        IPositionManager.Position memory position = IPositionManager(POSITION_MANAGER).positions(tokenId);

        (bool success, bytes memory data) =
            POSITION_MANAGER.staticcall(abi.encodeWithSignature("positions(uint256)", tokenId));

        assertTrue(success);

        IPositionManager.Position memory rawPosition = abi.decode(data, (IPositionManager.Position));

        assertEq(position.token0, rawPosition.token0);
        assertEq(position.token1, rawPosition.token1);
        assertEq(position.fee, rawPosition.fee);
        assertEq(position.liquidity, rawPosition.liquidity);
        assertEq(position.tokensOwed0, rawPosition.tokensOwed0);
        assertEq(position.tokensOwed1, rawPosition.tokensOwed1);
    }

    function test_CanReadRealPositionOwner() public view {
        uint256 tokenId = 1_224_792;

        address owner = IERC721(POSITION_MANAGER).ownerOf(tokenId);

        assertTrue(owner != address(0));
    }

    function test_RealUniswapPositionCanBeLockedIntoFort() public {
        uint256 tokenId = 1_224_792;
        address beneficiary = address(0xB0B);
        address fortFeeRecipient = address(0xFEE);

        IERC721 positionManager = IERC721(POSITION_MANAGER);
        address owner = positionManager.ownerOf(tokenId);

        FortLocks fort = new FortLocks(fortFeeRecipient);

        vm.startPrank(owner);

        positionManager.approve(address(fort), tokenId);
        fort.lock(tokenId, beneficiary);

        vm.stopPrank();

        assertEq(positionManager.ownerOf(tokenId), address(fort));
        assertEq(fort.locks(tokenId), beneficiary);
    }

    function test_RealLockedPositionCannotBeRecovered() public {
        uint256 tokenId = 1_224_792;
        address beneficiary = address(0xB0B);
        address fortFeeRecipient = address(0xFEE);

        IERC721 positionManager = IERC721(POSITION_MANAGER);
        address originalOwner = positionManager.ownerOf(tokenId);

        FortLocks fort = new FortLocks(fortFeeRecipient);

        vm.startPrank(originalOwner);
        positionManager.approve(address(fort), tokenId);
        fort.lock(tokenId, beneficiary);
        vm.stopPrank();

        assertEq(positionManager.ownerOf(tokenId), address(fort));

        vm.prank(originalOwner);
        vm.expectRevert();
        positionManager.transferFrom(address(fort), originalOwner, tokenId);

        vm.prank(beneficiary);
        vm.expectRevert();
        positionManager.transferFrom(address(fort), beneficiary, tokenId);

        assertEq(positionManager.ownerOf(tokenId), address(fort));
    }

    function test_CanDecreaseRealPositionLiquidityBeforeLock() public {
        uint256 tokenId = 1_224_760;

        IPositionManager positionManager = IPositionManager(POSITION_MANAGER);

        address owner = IERC721(POSITION_MANAGER).ownerOf(tokenId);

        IPositionManager.Position memory beforePosition = positionManager.positions(tokenId);

        uint128 liquidityToRemove = beforePosition.liquidity / 1_000_000;

        assertGt(liquidityToRemove, 0);

        vm.prank(owner);

        IPositionManagerTest(POSITION_MANAGER)
            .decreaseLiquidity(
                IPositionManagerTest.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

        IPositionManager.Position memory afterPosition = positionManager.positions(tokenId);

        assertEq(afterPosition.liquidity, beforePosition.liquidity - liquidityToRemove);

        assertTrue(afterPosition.tokensOwed0 > 0 || afterPosition.tokensOwed1 > 0);
    }

    function test_PreLockOwedTokensAreFlushedWithoutFortFee() public {
        uint256 tokenId = 1_224_760;
        address beneficiary = address(0xB0B);
        address fortFeeRecipient = address(0xFEE);

        IPositionManager positionManager = IPositionManager(POSITION_MANAGER);

        address owner = IERC721(POSITION_MANAGER).ownerOf(tokenId);

        IPositionManager.Position memory position = positionManager.positions(tokenId);
        uint128 liquidityToRemove = position.liquidity / 1_000_000;

        assertGt(liquidityToRemove, 0);

        vm.prank(owner);

        IPositionManagerTest(POSITION_MANAGER)
            .decreaseLiquidity(
                IPositionManagerTest.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

        position = positionManager.positions(tokenId);

        assertTrue(position.tokensOwed0 > 0 || position.tokensOwed1 > 0);

        FortLocks fort = new FortLocks(fortFeeRecipient);

        vm.startPrank(owner);
        IERC721(POSITION_MANAGER).approve(address(fort), tokenId);
        fort.lock(tokenId, beneficiary);
        vm.stopPrank();

        assertEq(IERC20(position.token0).balanceOf(beneficiary), position.tokensOwed0);

        assertEq(IERC20(position.token1).balanceOf(beneficiary), position.tokensOwed1);

        assertEq(IERC20(position.token0).balanceOf(fortFeeRecipient), 0);

        assertEq(IERC20(position.token1).balanceOf(fortFeeRecipient), 0);
    }

    function test_RealSwapCreatesFeesAfterLock() public {
        uint256 tokenId = 1_224_760;
        address beneficiary = address(0xB0B);
        address fortFeeRecipient = address(0xFEE);

        IERC721 positionNft = IERC721(POSITION_MANAGER);
        address owner = positionNft.ownerOf(tokenId);

        FortLocks fort = new FortLocks(fortFeeRecipient);

        vm.startPrank(owner);
        positionNft.approve(address(fort), tokenId);
        fort.lock(tokenId, beneficiary);
        vm.stopPrank();

        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        address token0 = 0x69Df80cB0c460bC6bA0c35018a9D31A044b56ed8;

        address trader = address(0xCAFE);

        vm.deal(trader, 1 ether);

        vm.startPrank(trader);

        IWETH(weth).deposit{value: 0.01 ether}();
        IWETH(weth).approve(SWAP_ROUTER, 0.01 ether);

        ISwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: token0,
                    fee: 10_000,
                    recipient: trader,
                    deadline: block.timestamp,
                    amountIn: 0.01 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

        vm.stopPrank();

        vm.prank(beneficiary);
        (uint256 amount0, uint256 amount1) = fort.collectFees(tokenId);

        assertTrue(amount0 > 0 || amount1 > 0);

        uint256 fortFee0 = (amount0 * fort.FORT_FEE_BPS()) / fort.BPS_DENOMINATOR();

        uint256 fortFee1 = (amount1 * fort.FORT_FEE_BPS()) / fort.BPS_DENOMINATOR();

        assertEq(IERC20(token0).balanceOf(fortFeeRecipient), fortFee0);

        assertEq(IERC20(weth).balanceOf(fortFeeRecipient), fortFee1);

        assertEq(IERC20(token0).balanceOf(beneficiary), amount0 - fortFee0);

        assertEq(IERC20(weth).balanceOf(beneficiary), amount1 - fortFee1);
    }
}
