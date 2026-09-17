// SPDX-License-Identifier: MIT
// CK · MrT · I&S assoc

pragma solidity 0.8.35;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";

/// @title Fort Locks
/// @notice Permanently locks Uniswap V3 liquidity position NFTs while allowing
///         an immutable beneficiary to collect post-lock trading fees.
/// @dev Locked position NFTs cannot be withdrawn, transferred, decreased,
///      burned, migrated, or recovered through this contract.
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
    error NotLocked();

    /// @notice Fort's share of post-lock collected trading fees: 0.9%.
    /// @dev Expressed in basis points; 90 / 10,000 = 0.009.
    uint256 public constant FORT_FEE_BPS = 90;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Address that permanently receives Fort's 0.9% share of collected fees.
    /// @dev Set once at deployment and cannot be changed.
    address public immutable FORT_FEE_RECIPIENT;

    /// @notice Permanent record of the beneficiary entitled to collect post-lock fees.
    /// @dev Once created, the beneficiary cannot be changed.
    struct Lock {
        address beneficiary;
    }
    /// @notice Canonical Uniswap V3 NonfungiblePositionManager on Ethereum mainnet.
    /// @dev Fort accepts position NFTs only from this fixed address.
    address public constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    /// @notice Returns the permanent lock record for a Uniswap V3 position token ID.
    /// @dev A zero beneficiary means the token ID has not been locked through Fort.
    mapping(uint256 tokenId => Lock lockData) public locks;

    /// @dev Carries fractional Fort fee numerators between collections so splitting
    ///      collections cannot reduce Fort's cumulative fee.
    mapping(uint256 tokenId => uint256 remainder0) private _feeRemainder0;
    mapping(uint256 tokenId => uint256 remainder1) private _feeRemainder1;

    /// @notice Deploys Fort with its permanent protocol fee recipient.
    /// @param _fortFeeRecipient Address that receives Fort's 0.9% share of post-lock fees.
    constructor(address _fortFeeRecipient) {
        if (_fortFeeRecipient == address(0)) {
            revert ZeroAddress();
        }

        FORT_FEE_RECIPIENT = _fortFeeRecipient;
    }

    /// @notice Permanently locks a Uniswap V3 position NFT for a beneficiary.
    /// @dev Any tokens already owed by the position are sent directly to the beneficiary
    ///      during locking and are not charged the Fort fee.
    /// @param tokenId Uniswap V3 position NFT token ID to lock.
    /// @param beneficiary Address permanently entitled to collect post-lock fees.
    function lock(uint256 tokenId, address beneficiary) external nonReentrant {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (locks[tokenId].beneficiary != address(0)) revert AlreadyLocked();

        IERC721 positionManager = IERC721(POSITION_MANAGER);

        if (positionManager.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner();
        }

        locks[tokenId] = Lock({beneficiary: beneficiary});

        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);

        _flushPreExistingOwedTokens(tokenId, beneficiary);

        // Emitted only after the NFT transfer and initial flush complete successfully.
        // lock() is protected by nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Locked(tokenId, beneficiary);
    }

    /// @notice Collects post-lock trading fees for a locked position.
    /// @dev Anyone may call this function. Fort receives a cumulative 0.9% of
    ///      post-lock collected fees and the permanent beneficiary receives the remainder.
    /// @param tokenId Uniswap V3 position NFT token ID.
    /// @return amount0 Total amount of token0 collected from the position.
    /// @return amount1 Total amount of token1 collected from the position.
    function collectFees(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Lock memory lockData = locks[tokenId];

        if (lockData.beneficiary == address(0)) {
            revert NotLocked();
        }

        (address token0, address token1) = _getPositionTokens(tokenId);

        (amount0, amount1) = IPositionManager(POSITION_MANAGER)
            .collect(
                IPositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

        uint256 feeNumerator0 = (amount0 * FORT_FEE_BPS) + _feeRemainder0[tokenId];
        uint256 feeNumerator1 = (amount1 * FORT_FEE_BPS) + _feeRemainder1[tokenId];

        uint256 fortFee0 = feeNumerator0 / BPS_DENOMINATOR;
        uint256 fortFee1 = feeNumerator1 / BPS_DENOMINATOR;

        _feeRemainder0[tokenId] = feeNumerator0 % BPS_DENOMINATOR;
        _feeRemainder1[tokenId] = feeNumerator1 % BPS_DENOMINATOR;

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
        // Emitted only after all fee transfers complete successfully.
        // collectFees() is protected by nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeesCollected(tokenId, lockData.beneficiary, amount0, amount1, fortFee0, fortFee1);
    }

    /// @dev Reads the two underlying token addresses for a Uniswap V3 position.
    /// @param tokenId Uniswap V3 position NFT token ID.
    /// @return token0 Address of the position's token0.
    /// @return token1 Address of the position's token1.
    function _getPositionTokens(uint256 tokenId) internal view returns (address token0, address token1) {
        IPositionManager.Position memory position = IPositionManager(POSITION_MANAGER).positions(tokenId);

        token0 = position.token0;
        token1 = position.token1;
    }

    /// @dev Flushes all amounts owed before locking directly to the beneficiary,
    ///      ensuring Fort charges no fee on pre-lock owed amounts.
    function _flushPreExistingOwedTokens(uint256 tokenId, address beneficiary) internal {
        IPositionManager(POSITION_MANAGER)
            .collect(
                IPositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: beneficiary,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @notice Accepts only Uniswap V3 position NFTs transferred as part of Fort's lock process.
    /// @dev Rejects arbitrary ERC721s and direct transfers that bypass lock().
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != POSITION_MANAGER) revert InvalidNFT();
        if (operator != address(this)) revert InvalidTransfer();

        return IERC721Receiver.onERC721Received.selector;
    }
}
