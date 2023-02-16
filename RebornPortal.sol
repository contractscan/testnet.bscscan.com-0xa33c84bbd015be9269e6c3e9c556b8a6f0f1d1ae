// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {IRebornPortal} from "src/interfaces/IRebornPortal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BitMapsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/BitMapsUpgradeable.sol";

import {SafeOwnableUpgradeable} from "@p12/contracts-lib/contracts/access/SafeOwnableUpgradeable.sol";

import {RebornRankReplacer} from "src/RebornRankReplacer.sol";
import {RebornStorage} from "src/RebornStorage.sol";
import {IRebornToken} from "src/interfaces/IRebornToken.sol";
import {RenderEngine} from "src/lib/RenderEngine.sol";
import {RBT} from "src/RBT.sol";

contract RebornPortal is
    IRebornPortal,
    SafeOwnableUpgradeable,
    UUPSUpgradeable,
    RebornStorage,
    ERC721Upgradeable,
    ReentrancyGuardUpgradeable,
    RebornRankReplacer
{
    using SafeERC20Upgradeable for IRebornToken;
    using BitMapsUpgradeable for BitMapsUpgradeable.BitMap;

    function initialize(
        RBT rebornToken_,
        uint256 soupPrice_,
        uint256 priceAndPoint_,
        address owner_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        rebornToken = rebornToken_;
        soupPrice = soupPrice_;
        _priceAndPoint = priceAndPoint_;
        __Ownable_init(owner_);
        __ERC721_init(name_, symbol_);
        __ReentrancyGuard_init();
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /**
     * @dev keep it for backwards compatibility
     */
    function incarnate(Innate memory innate) external payable override {
        _incarnate(innate);
    }

    function incarnate(Innate memory innate, address referrer)
        external
        payable
        override
    {
        _incarnate(innate);
        _refer(referrer);
    }

    /**
     * @dev keep it for backwards compatibility
     */
    function incarnate(
        Innate memory innate,
        uint256 amount,
        uint256 deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external payable override {
        _permit(amount, deadline, r, s, v);
        _incarnate(innate);
    }

    /**
     * @dev incarnate
     */
    function incarnate(
        Innate memory innate,
        uint256 amount,
        uint256 deadline,
        address referrer,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external payable override {
        _permit(amount, deadline, r, s, v);
        _incarnate(innate);
        _refer(referrer);
    }

    /**
     * @dev engrave the result on chain and reward
     * @param seed uuid seed string without "-"  in bytes32
     */
    function engrave(
        bytes32 seed,
        address user,
        uint256 reward,
        uint256 score,
        uint256 age,
        // for backward compatibility, do not delete
        uint256 locate
    ) external override onlySigner {
        // enter the rank list
        uint256 tokenId = _enter(score);

        details[tokenId] = LifeDetail(
            seed,
            user,
            ++rounds[user],
            uint16(age),
            0,
            // set cost to 0 temporary, should implement later
            uint128(0 / 10**18),
            uint128(reward / 10**18)
        );
        // mint erc721
        _safeMint(user, tokenId);
        // mint $REBORN reward
        rebornToken.mint(user, reward);

        // mint to referrer
        _rewardReferrer(user, score, reward);

        emit Engrave(seed, user, tokenId, score, reward);
    }

    /**
     * @dev baptise
     */
    function baptise(address user, uint256 amount)
        external
        override
        onlySigner
    {
        if (baptism.get(uint160(user))) {
            revert AlreadyBaptised();
        }

        baptism.set(uint160(user));

        rebornToken.mint(user, amount);

        emit Baptise(user, amount);
    }

    /**
     * @dev degen infuse $REBORN to tombstone
     * @dev expect for bliss
     */
    function infuse(uint256 tokenId, uint256 amount) external override {
        _requireMinted(tokenId);

        rebornToken.transferFrom(msg.sender, address(this), amount);

        Pool storage pool = pools[tokenId];
        pool.totalAmount += amount;

        Portfolio storage portfolio = portfolios[msg.sender][tokenId];
        portfolio.accumulativeAmount += amount;

        emit Infuse(msg.sender, tokenId, amount);
    }

    /**
     * @dev degen get $REBORN back
     */
    function dry(uint256 tokenId, uint256 amount) external override {
        Pool storage pool = pools[tokenId];
        pool.totalAmount -= amount;

        Portfolio storage portfolio = portfolios[msg.sender][tokenId];
        portfolio.accumulativeAmount -= amount;

        rebornToken.transfer(msg.sender, amount);

        emit Dry(msg.sender, tokenId, amount);
    }

    /**
     * @dev set soup price
     */
    function setSoupPrice(uint256 price) external override onlyOwner {
        soupPrice = price;
        emit NewSoupPrice(price);
    }

    /**
     * @dev set other price
     */
    function setPriceAndPoint(uint256 pricePoint) external override onlyOwner {
        _priceAndPoint = pricePoint;
        emit NewPricePoint(_priceAndPoint);
    }

    /**
     * @dev warning: only called onece during test
     * @dev abandoned in production
     */
    function initAfterUpgrade(string memory name_, string memory symbol_)
        external
        onlyOwner
    {
        __ERC721_init(name_, symbol_);
        __ReentrancyGuard_init();
    }

    /**
     * @dev update signer
     */
    function updateSigners(
        address[] calldata toAdd,
        address[] calldata toRemove
    ) public onlyOwner {
        for (uint256 i = 0; i < toAdd.length; i++) {
            signers[toAdd[i]] = true;
            emit SignerUpdate(toAdd[i], true);
        }
        for (uint256 i = 0; i < toRemove.length; i++) {
            delete signers[toRemove[i]];
            emit SignerUpdate(toRemove[i], false);
        }
    }

    /**
     * @dev withdraw all $REBORN, only called during development
     */
    function withdrawAll() external onlyOwner {
        rebornToken.transfer(msg.sender, rebornToken.balanceOf(address(this)));
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        _requireMinted(tokenId);

        string memory metadata = Base64.encode(
            bytes(
                string.concat(
                    '{"name": "',
                    name(),
                    '","description":"',
                    "",
                    '","image":"',
                    "data:image/svg+xml;base64,",
                    Base64.encode(
                        bytes(
                            RenderEngine.render(
                                "seed",
                                scores[tokenId],
                                details[tokenId].round,
                                details[tokenId].age,
                                details[tokenId].creator,
                                details[tokenId].reward
                            )
                        )
                    ),
                    '"}'
                )
            )
        );

        return string.concat("data:application/json;base64,", metadata);
    }

    /**
     * @dev run erc20 permit to approve
     */
    function _permit(
        uint256 amount,
        uint256 deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal {
        rebornToken.permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
    }

    /**
     * @dev implementation of incarnate
     */
    function _incarnate(Innate memory innate) internal {
        if (msg.value < soupPrice) {
            revert InsufficientAmount();
        }
        // transfer redundant native token back
        payable(msg.sender).transfer(msg.value - soupPrice);

        // reborn token needed
        uint256 rbtAmount = talentPrice(innate.talent) +
            propertyPrice(innate.properties);

        /// burn token directly
        rebornToken.burnFrom(msg.sender, rbtAmount);

        emit Incarnate(
            msg.sender,
            talentPoint(innate.talent),
            propertyPoint(innate.properties),
            innate.talent,
            innate.properties,
            rbtAmount
        );
    }

    /**
     * @dev record referrer relationship, only one layer
     */
    function _refer(address referrer) internal {
        if (referrals[msg.sender] == address(0)) {
            referrals[msg.sender] = referrer;
            emit Refer(msg.sender, referrer);
        }
    }

    /**
     * @dev mint refer reward to referee's referrer
     */
    function _rewardReferrer(
        address referee,
        uint256 score,
        uint256 amount
    ) internal {
        (address referrar, uint256 referReward) = calculateReferReward(
            referee,
            score,
            amount
        );
        if (referrar != address(0)) {
            rebornToken.mint(referrar, referReward);
            emit ReferReward(referrar, referReward);
        }
    }

    /**
     * @dev returns refereral and refer reward
     * @param referee referee address
     * @param score referee degen life score
     * @param amount reward to the referee, ERC20 amount
     */
    function calculateReferReward(
        address referee,
        uint256 score,
        uint256 amount
    ) public view returns (address referrar, uint256 referReward) {
        referrar = referrals[referee];
        if (score >= 100) {
            // refer reward ratio is temporary 0.2
            referReward = amount / 5;
        }
    }

    /**
     * @dev calculate talent price in $REBORN for each talent
     */
    function talentPrice(TALENT talent) public view returns (uint256) {
        return
            (((_priceAndPoint >> 192) >> (uint8(talent) * 8)) & 0xff) * 1 ether;
    }

    /**
     * @dev calculate talent point for each talent
     */
    function talentPoint(TALENT talent) public view returns (uint256) {
        return ((_priceAndPoint >> 128) >> (uint8(talent) * 8)) & 0xff;
    }

    /**
     * @dev calculate properties price in $REBORN for each properties
     */
    function propertyPrice(PROPERTIES properties)
        public
        view
        returns (uint256)
    {
        return
            (((_priceAndPoint >> 64) >> (uint8(properties) * 8)) & 0xff) *
            1 ether;
    }

    /**
     * @dev calculate properties point for each property
     */
    function propertyPoint(PROPERTIES properties)
        public
        view
        returns (uint256)
    {
        return (_priceAndPoint >> (uint8(properties) * 8)) & 0xff;
    }

    /**
     * @dev read pool attribute
     */
    function getPool(uint256 tokenId) public view returns (Pool memory) {
        _requireMinted(tokenId);
        return pools[tokenId];
    }

    /**
     * @dev check signer implementation
     */
    function _checkSigner() internal view {
        if (!signers[msg.sender]) {
            revert NotSigner();
        }
    }

    /**
     * @dev only allow signer address can do something
     */
    modifier onlySigner() {
        _checkSigner();
        _;
    }
}