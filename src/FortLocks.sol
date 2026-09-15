// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPositionManagerCollect {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

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

    function positions(uint256 tokenId) external view returns (Position memory position);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

contract FortLocks is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    event Locked(uint256 indexed tokenId, address indexed beneficiary);
    event FeesCollected(
        uint256 indexed tokenId,
        address indexed beneficiary,
        uint256 amount0,
        uint256 amount1,
        uint256 fortFee0,
        uint256 fortFee1
    );
    error ZeroAddress();
    error NotTokenOwner();
    error AlreadyLocked();
    error InvalidNFT();
    error InvalidTransfer();
    error NotBeneficiary();

    uint256 public constant FORT_FEE_BPS = 90;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable FORT_FEE_RECIPIENT;

    struct Lock {
        address beneficiary;
    }

    address public immutable POSITION_MANAGER;

    mapping(uint256 tokenId => Lock lockData) public locks;

    constructor(address _positionManager, address _fortFeeRecipient) {
        if (_positionManager == address(0) || _fortFeeRecipient == address(0)) revert ZeroAddress();

        POSITION_MANAGER = _positionManager;
        FORT_FEE_RECIPIENT = _fortFeeRecipient;
    }

    function lock(uint256 tokenId, address beneficiary) external {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (locks[tokenId].beneficiary != address(0)) revert AlreadyLocked();

        IERC721 positionManager = IERC721(POSITION_MANAGER);

        if (positionManager.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner();
        }

        locks[tokenId] = Lock({beneficiary: beneficiary});

        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        emit Locked(tokenId, beneficiary);
    }

    function collectFees(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Lock memory lockData = locks[tokenId];

        if (lockData.beneficiary != msg.sender) {
            revert NotBeneficiary();
        }

        (address token0, address token1) = _getPositionTokens(tokenId);

        (amount0, amount1) = IPositionManagerCollect(POSITION_MANAGER)
            .collect(
                IPositionManagerCollect.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

        uint256 fortFee0 = (amount0 * FORT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 fortFee1 = (amount1 * FORT_FEE_BPS) / BPS_DENOMINATOR;

        if (fortFee0 > 0) {
            IERC20(token0).safeTransfer(FORT_FEE_RECIPIENT, fortFee0);
        }

        if (fortFee1 > 0) {
            IERC20(token1).safeTransfer(FORT_FEE_RECIPIENT, fortFee1);
        }

        if (amount0 > fortFee0) {
            IERC20(token0).safeTransfer(lockData.beneficiary, amount0 - fortFee0);
        }

        if (amount1 > fortFee1) {
            IERC20(token1).safeTransfer(lockData.beneficiary, amount1 - fortFee1);
        }
        emit FeesCollected(tokenId, lockData.beneficiary, amount0, amount1, fortFee0, fortFee1);
    }

    function _getPositionTokens(uint256 tokenId) internal view returns (address token0, address token1) {
        IPositionManagerCollect.Position memory position = IPositionManagerCollect(POSITION_MANAGER).positions(tokenId);

        token0 = position.token0;
        token1 = position.token1;
    }

    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != POSITION_MANAGER) revert InvalidNFT();
        if (operator != address(this)) revert InvalidTransfer();

        return IERC721Receiver.onERC721Received.selector;
    }
}
