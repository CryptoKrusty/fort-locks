// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {FortLocks, IPositionManagerCollect} from "../src/FortLocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    constructor() ERC20("Reentrant Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureAttack(FortLocks _fort, uint256 _tokenId) external {
        fort = _fort;
        tokenId = _tokenId;
        attackEnabled = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (attackEnabled) {
            attackEnabled = false;

            try fort.collectFees(tokenId) {
                reentryBlocked = false;
            } catch {
                reentryBlocked = true;
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

    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        token0 = new MockERC20("Token 0", "TK0");
        token1 = new MockERC20("Token 1", "TK1");

        positionManager = new MockPositionManager(token0, token1);

        fort = new FortLocks(address(positionManager), fortFeeRecipient);

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

        MockPositionManager maliciousPositionManager =
            new MockPositionManager(MockERC20(address(maliciousToken)), normalToken);

        FortLocks protectedFort = new FortLocks(address(maliciousPositionManager), fortFeeRecipient);

        uint256 attackTokenId = 777;
        uint256 fees = 1_000 ether;

        maliciousPositionManager.mint(locker, attackTokenId);

        vm.startPrank(locker);
        maliciousPositionManager.approve(address(protectedFort), attackTokenId);
        protectedFort.lock(attackTokenId, beneficiary);
        vm.stopPrank();

        maliciousToken.mint(address(maliciousPositionManager), fees);

        maliciousPositionManager.setFees(attackTokenId, fees, 0);

        maliciousToken.configureAttack(protectedFort, attackTokenId);

        vm.prank(beneficiary);
        protectedFort.collectFees(attackTokenId);

        assertTrue(maliciousToken.reentryBlocked());

        uint256 expectedFortFee = (fees * 90) / 10_000;

        assertEq(maliciousToken.balanceOf(fortFeeRecipient), expectedFortFee);

        assertEq(maliciousToken.balanceOf(beneficiary), fees - expectedFortFee);

        assertEq(maliciousToken.balanceOf(address(protectedFort)), 0);

        assertEq(maliciousPositionManager.ownerOf(attackTokenId), address(protectedFort));
    }
}
