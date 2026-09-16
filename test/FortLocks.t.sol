// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {FortLocks, IPositionManagerCollect} from "../src/FortLocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReentrantERC20 is ERC20 {
    FortLocks public fort;
    uint256 public tokenId;
    bool public attackEnabled;
    bool public reentryBlocked;
    bool public attackLock;
    bytes public reentryRevertData;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureAttack(FortLocks _fort, uint256 _tokenId) external {
        fort = _fort;
        tokenId = _tokenId;
        attackEnabled = true;
    }

    function configureLockAttack(FortLocks _fort, uint256 _tokenId) external {
        fort = _fort;
        tokenId = _tokenId;
        attackEnabled = true;
        attackLock = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (attackEnabled) {
            attackEnabled = false;

            if (attackLock) {
                try fort.lock(tokenId, address(this)) {
                    reentryBlocked = false;
                } catch (bytes memory reason) {
                    reentryBlocked = true;
                    reentryRevertData = reason;
                }
            } else {
                try fort.collectFees(tokenId) {
                    reentryBlocked = false;
                } catch (bytes memory reason) {
                    reentryBlocked = true;
                    reentryRevertData = reason;
                }
            }
        }

        return super.transfer(to, value);
    }
}

contract MockPositionManager is ERC721 {
    mapping(uint256 tokenId => uint256 amount0) public fees0;
    mapping(uint256 tokenId => uint256 amount1) public fees1;
    MockERC20 public token0;
    MockERC20 public token1;

    constructor(MockERC20 _token0, MockERC20 _token1) ERC721("Mock Uniswap V3 Position", "MUV3") {
        token0 = _token0;
        token1 = _token1;
    }

    function initializeTokens(MockERC20 _token0, MockERC20 _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        fees0[tokenId] = amount0;
        fees1[tokenId] = amount1;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), address(token0), address(token1), 3000, 0, 0, 1, 0, 0, 0, 0);
    }

    function collect(IPositionManagerCollect.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = fees0[params.tokenId];
        amount1 = fees1[params.tokenId];

        fees0[params.tokenId] = 0;
        fees1[params.tokenId] = 0;
        if (amount0 > 0) {
            token0.transfer(params.recipient, amount0);
        }

        if (amount1 > 0) {
            token1.transfer(params.recipient, amount1);
        }
    }
}

contract RandomNFT is ERC721 {
    constructor() ERC721("Random NFT", "RND") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract FortLocksTest is Test {
    FortLocks fort;
    MockPositionManager positionManager;
    MockERC20 token0;
    MockERC20 token1;

    address locker = address(0xA11CE);
    address beneficiary = address(0xB0B);
    address fortFeeRecipient = address(0xFEE);
    address constant CANONICAL_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        token0 = new MockERC20("Token 0", "TK0");
        token1 = new MockERC20("Token 1", "TK1");

        MockPositionManager implementation = new MockPositionManager(token0, token1);

        vm.etch(CANONICAL_POSITION_MANAGER, address(implementation).code);

        positionManager = MockPositionManager(CANONICAL_POSITION_MANAGER);

        positionManager.initializeTokens(token0, token1);

        fort = new FortLocks(fortFeeRecipient);

        positionManager.mint(locker, TOKEN_ID);
    }

    function test_LockTransfersNFTIntoFort() public {
        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);

        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_LockStoresBeneficiary() public {
        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);

        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        (address storedBeneficiary) = fort.locks(TOKEN_ID);

        assertEq(storedBeneficiary, beneficiary);
    }

    function test_RevertIfBeneficiaryIsZeroAddress() public {
        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);

        vm.expectRevert(FortLocks.ZeroAddress.selector);

        fort.lock(TOKEN_ID, address(0));

        vm.stopPrank();
    }

    function test_RevertIfCallerIsNotTokenOwner() public {
        address attacker = address(0xBAD);

        vm.prank(locker);
        positionManager.approve(address(fort), TOKEN_ID);

        vm.expectRevert(FortLocks.NotTokenOwner.selector);

        vm.prank(attacker);
        fort.lock(TOKEN_ID, beneficiary);
    }

    function test_RejectsArbitraryERC721() public {
        RandomNFT randomNFT = new RandomNFT();

        uint256 randomTokenId = 77;

        randomNFT.mint(address(this), randomTokenId);

        vm.expectRevert(FortLocks.InvalidNFT.selector);

        randomNFT.safeTransferFrom(address(this), address(fort), randomTokenId);
    }

    function test_RejectsDirectPositionNFTTransfer() public {
        vm.startPrank(locker);

        vm.expectRevert(FortLocks.InvalidTransfer.selector);

        positionManager.safeTransferFrom(locker, address(fort), TOKEN_ID);

        vm.stopPrank();
    }

    function test_CollectSplitsFeesCorrectly() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 fee0 = 1_000 ether;
        uint256 fee1 = 500 ether;

        token0.mint(address(positionManager), fee0);
        token1.mint(address(positionManager), fee1);

        positionManager.setFees(TOKEN_ID, fee0, fee1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 fortFee0 = (fee0 * 90) / 10_000;
        uint256 fortFee1 = (fee1 * 90) / 10_000;

        assertEq(token0.balanceOf(fortFeeRecipient), fortFee0);
        assertEq(token1.balanceOf(fortFeeRecipient), fortFee1);

        assertEq(token0.balanceOf(beneficiary), fee0 - fortFee0);

        assertEq(token1.balanceOf(beneficiary), fee1 - fortFee1);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);
    }

    function test_RevertIfNonBeneficiaryCollectsFees() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        address attacker = address(0xBAD);

        vm.expectRevert(FortLocks.NotBeneficiary.selector);
        vm.prank(attacker);
        fort.collectFees(TOKEN_ID);
    }

    function test_CollectFeeRoundingFavorsBeneficiary() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 fee0 = 111;
        uint256 fee1 = 111;

        token0.mint(address(positionManager), fee0);
        token1.mint(address(positionManager), fee1);

        positionManager.setFees(TOKEN_ID, fee0, fee1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        assertEq(token0.balanceOf(fortFeeRecipient), 0);
        assertEq(token1.balanceOf(fortFeeRecipient), 0);

        assertEq(token0.balanceOf(beneficiary), 111);
        assertEq(token1.balanceOf(beneficiary), 111);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);
    }

    function test_CollectMinimumNonZeroFortFee() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 fee0 = 112;
        uint256 fee1 = 112;

        token0.mint(address(positionManager), fee0);
        token1.mint(address(positionManager), fee1);

        positionManager.setFees(TOKEN_ID, fee0, fee1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        assertEq(token0.balanceOf(fortFeeRecipient), 1);
        assertEq(token1.balanceOf(fortFeeRecipient), 1);

        assertEq(token0.balanceOf(beneficiary), 111);
        assertEq(token1.balanceOf(beneficiary), 111);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);
    }

    function test_CollectHandlesOneTokenWithZeroFees() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 fee0 = 1_000 ether;
        uint256 fee1 = 0;

        token0.mint(address(positionManager), fee0);

        positionManager.setFees(TOKEN_ID, fee0, fee1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 fortFee0 = (fee0 * 90) / 10_000;

        assertEq(token0.balanceOf(fortFeeRecipient), fortFee0);
        assertEq(token0.balanceOf(beneficiary), fee0 - fortFee0);

        assertEq(token1.balanceOf(fortFeeRecipient), 0);
        assertEq(token1.balanceOf(beneficiary), 0);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);
    }

    function test_CanCollectFeesRepeatedly() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 firstFee = 1_000 ether;

        token0.mint(address(positionManager), firstFee);
        positionManager.setFees(TOKEN_ID, firstFee, 0);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 secondFee = 500 ether;

        token0.mint(address(positionManager), secondFee);
        positionManager.setFees(TOKEN_ID, secondFee, 0);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 totalFees = firstFee + secondFee;
        uint256 expectedFortFee = ((firstFee * 90) / 10_000) + ((secondFee * 90) / 10_000);

        assertEq(token0.balanceOf(fortFeeRecipient), expectedFortFee);

        assertEq(token0.balanceOf(beneficiary), totalFees - expectedFortFee);

        assertEq(token0.balanceOf(address(fort)), 0);

        // The V3 position itself remains permanently held by Fort.
        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_CollectHandlesZeroFees() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        assertEq(token0.balanceOf(fortFeeRecipient), 0);
        assertEq(token1.balanceOf(fortFeeRecipient), 0);

        assertEq(token0.balanceOf(beneficiary), 0);
        assertEq(token1.balanceOf(beneficiary), 0);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_RevertCollectForUnlockedToken() public {
        uint256 unlockedTokenId = 999;

        vm.expectRevert(FortLocks.NotBeneficiary.selector);
        vm.prank(beneficiary);
        fort.collectFees(unlockedTokenId);
    }

    function test_LockedNFTCannotBeTransferredByBeneficiary() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        vm.startPrank(beneficiary);

        vm.expectRevert();
        positionManager.transferFrom(address(fort), beneficiary, TOKEN_ID);

        vm.stopPrank();

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_LockedNFTCannotBeTransferredByOriginalOwner() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        vm.startPrank(locker);

        vm.expectRevert();
        positionManager.transferFrom(address(fort), locker, TOKEN_ID);

        vm.stopPrank();

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function testFuzz_ArbitraryAddressCannotTransferLockedNFT(address caller) public {
        vm.assume(caller != address(fort));

        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        vm.startPrank(caller);

        vm.expectRevert();
        positionManager.transferFrom(address(fort), caller, TOKEN_ID);

        vm.stopPrank();

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_BeneficiaryNeverReceivesNFTApproval() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        assertEq(positionManager.getApproved(TOKEN_ID), address(0));

        assertFalse(positionManager.isApprovedForAll(address(fort), beneficiary));

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_LockEmitsLockedEvent() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);

        vm.expectEmit(true, true, false, false);
        emit FortLocks.Locked(TOKEN_ID, beneficiary);

        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();
    }

    function test_CollectEmitsFeesCollectedEvent() public {
        vm.startPrank(locker);
        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);
        vm.stopPrank();

        uint256 fee0 = 1_000 ether;
        uint256 fee1 = 500 ether;

        token0.mint(address(positionManager), fee0);
        token1.mint(address(positionManager), fee1);

        positionManager.setFees(TOKEN_ID, fee0, fee1);

        uint256 fortFee0 = (fee0 * 90) / 10_000;
        uint256 fortFee1 = (fee1 * 90) / 10_000;

        vm.expectEmit(true, true, false, true);
        emit FortLocks.FeesCollected(TOKEN_ID, beneficiary, fee0, fee1, fortFee0, fortFee1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);
    }

    function test_ReentrancyDuringFeeDistributionIsBlocked() public {
        ReentrantERC20 maliciousToken = new ReentrantERC20();
        MockERC20 normalToken = new MockERC20("Normal Token", "NORMAL");

        positionManager.initializeTokens(MockERC20(address(maliciousToken)), normalToken);

        FortLocks protectedFort = new FortLocks(fortFeeRecipient);

        uint256 attackTokenId = 777;
        uint256 fees = 1_000 ether;

        positionManager.mint(locker, attackTokenId);

        vm.startPrank(locker);
        positionManager.approve(address(protectedFort), attackTokenId);
        protectedFort.lock(attackTokenId, beneficiary);
        vm.stopPrank();

        maliciousToken.mint(address(positionManager), fees);

        positionManager.setFees(attackTokenId, fees, 0);

        maliciousToken.configureAttack(protectedFort, attackTokenId);

        vm.prank(beneficiary);
        protectedFort.collectFees(attackTokenId);

        assertTrue(maliciousToken.reentryBlocked());
        assertEq(bytes4(maliciousToken.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        uint256 expectedFortFee = (fees * 90) / 10_000;

        assertEq(maliciousToken.balanceOf(fortFeeRecipient), expectedFortFee);

        assertEq(maliciousToken.balanceOf(beneficiary), fees - expectedFortFee);

        assertEq(maliciousToken.balanceOf(address(protectedFort)), 0);

        assertEq(positionManager.ownerOf(attackTokenId), address(protectedFort));
    }

    function test_ReentrancyDuringInitialFlushIsBlocked() public {
        ReentrantERC20 maliciousToken = new ReentrantERC20();
        MockERC20 normalToken = new MockERC20("Normal Token", "NORMAL");

        positionManager.initializeTokens(MockERC20(address(maliciousToken)), normalToken);

        FortLocks protectedFort = new FortLocks(fortFeeRecipient);

        uint256 attackTokenId = 888;
        uint256 preExistingAmount = 1_000 ether;

        positionManager.mint(locker, attackTokenId);

        maliciousToken.mint(address(positionManager), preExistingAmount);

        positionManager.setFees(attackTokenId, preExistingAmount, 0);

        maliciousToken.configureLockAttack(protectedFort, attackTokenId);

        vm.startPrank(locker);

        positionManager.approve(address(protectedFort), attackTokenId);

        protectedFort.lock(attackTokenId, beneficiary);

        vm.stopPrank();

        assertTrue(maliciousToken.reentryBlocked());

        assertEq(bytes4(maliciousToken.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        assertEq(maliciousToken.balanceOf(beneficiary), preExistingAmount);

        assertEq(maliciousToken.balanceOf(fortFeeRecipient), 0);

        assertEq(maliciousToken.balanceOf(address(protectedFort)), 0);

        assertEq(positionManager.ownerOf(attackTokenId), address(protectedFort));

        assertEq(protectedFort.locks(attackTokenId), beneficiary);
    }

    function test_PositionManagerIsCanonicalEthereumUniswapV3() public view {
        assertEq(fort.POSITION_MANAGER(), 0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    }

    function test_RevertIfFortFeeRecipientIsZeroAddress() public {
        vm.expectRevert(FortLocks.ZeroAddress.selector);
        new FortLocks(address(0));
    }

    function test_FortFeeIsPointNinePercent() public view {
        assertEq(fort.FORT_FEE_BPS(), 90);
        assertEq(fort.BPS_DENOMINATOR(), 10_000);
    }

    function test_LockFlushesPreExistingOwedTokensWithoutFortFee() public {
        uint256 preExistingAmount0 = 10 ether;
        uint256 preExistingAmount1 = 20 ether;

        token0.mint(address(positionManager), preExistingAmount0);
        token1.mint(address(positionManager), preExistingAmount1);

        positionManager.setFees(TOKEN_ID, preExistingAmount0, preExistingAmount1);

        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        assertEq(token0.balanceOf(beneficiary), preExistingAmount0);
        assertEq(token1.balanceOf(beneficiary), preExistingAmount1);

        assertEq(token0.balanceOf(fortFeeRecipient), 0);
        assertEq(token1.balanceOf(fortFeeRecipient), 0);

        assertEq(token0.balanceOf(address(fort)), 0);
        assertEq(token1.balanceOf(address(fort)), 0);

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_FortFeeRecipientHasNoControlOverLockedNFT() public {
        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        vm.prank(fortFeeRecipient);

        vm.expectRevert();

        positionManager.transferFrom(address(fort), fortFeeRecipient, TOKEN_ID);

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_LockedNFTNeverHasExternalApproval() public {
        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        assertEq(positionManager.getApproved(TOKEN_ID), address(0));
    }

    function test_FeesAfterInitialFlushUseNormalFortFee() public {
        uint256 preExistingAmount = 100 ether;
        uint256 laterFees = 200 ether;

        token0.mint(address(positionManager), preExistingAmount + laterFees);

        positionManager.setFees(TOKEN_ID, preExistingAmount, 0);

        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        // Everything owed before locking goes to the beneficiary.
        assertEq(token0.balanceOf(beneficiary), preExistingAmount);

        assertEq(token0.balanceOf(fortFeeRecipient), 0);

        // Simulate fees generated after the position is locked.
        positionManager.setFees(TOKEN_ID, laterFees, 0);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 expectedFortFee = (laterFees * 90) / 10_000;

        assertEq(token0.balanceOf(fortFeeRecipient), expectedFortFee);

        assertEq(token0.balanceOf(beneficiary), preExistingAmount + laterFees - expectedFortFee);

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }

    function test_BothTokensFlushThenUseNormalFortFee() public {
        uint256 preExisting0 = 100 ether;
        uint256 preExisting1 = 300 ether;

        uint256 laterFees0 = 200 ether;
        uint256 laterFees1 = 400 ether;

        token0.mint(address(positionManager), preExisting0 + laterFees0);

        token1.mint(address(positionManager), preExisting1 + laterFees1);

        // Amounts already owed before the NFT enters Fort.
        positionManager.setFees(TOKEN_ID, preExisting0, preExisting1);

        vm.startPrank(locker);

        positionManager.approve(address(fort), TOKEN_ID);
        fort.lock(TOKEN_ID, beneficiary);

        vm.stopPrank();

        // Pre-existing amounts are flushed with zero Fort fee.
        assertEq(token0.balanceOf(beneficiary), preExisting0);

        assertEq(token1.balanceOf(beneficiary), preExisting1);

        assertEq(token0.balanceOf(fortFeeRecipient), 0);

        assertEq(token1.balanceOf(fortFeeRecipient), 0);

        // Simulate new fees generated after the permanent lock.
        positionManager.setFees(TOKEN_ID, laterFees0, laterFees1);

        vm.prank(beneficiary);
        fort.collectFees(TOKEN_ID);

        uint256 expectedFortFee0 = (laterFees0 * 90) / 10_000;

        uint256 expectedFortFee1 = (laterFees1 * 90) / 10_000;

        assertEq(token0.balanceOf(fortFeeRecipient), expectedFortFee0);

        assertEq(token1.balanceOf(fortFeeRecipient), expectedFortFee1);

        assertEq(token0.balanceOf(beneficiary), preExisting0 + laterFees0 - expectedFortFee0);

        assertEq(token1.balanceOf(beneficiary), preExisting1 + laterFees1 - expectedFortFee1);

        assertEq(token0.balanceOf(address(fort)), 0);

        assertEq(token1.balanceOf(address(fort)), 0);

        assertEq(positionManager.ownerOf(TOKEN_ID), address(fort));
    }
}
