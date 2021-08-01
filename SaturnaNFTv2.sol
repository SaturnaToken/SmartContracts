// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract saturnaNFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public FEE_MAX_PERCENT = 300;

    EnumerableSet.AddressSet private _supportedTokens; //payment token (ERC20)
    
    Counters.Counter private _itemIds;
    Counters.Counter public _tokenIds;
    
    mapping(uint256 => address) private _creators;

    struct Item {
        uint256 id;                     // Item Id
        address collection;             // Collection Contract address : ERC721
        uint256 tokenId;                // Token ID of ERC721
        bool mintable;                  // Edition ? Edition = Lazy Mint
        address creator;                // Item Creator address
        string uri;                     // Token URI
        uint256 count;                  // Edition Count ( For only Edition)
        uint256 price;                  // Asking Price ( )
        address currency;               // Asking Currency Token Address
        bool auctionable;               // Is this Timed Auction?
        uint256 startTime;              // Auction Start Time
        uint256 endTime;                // Auction End Time
        Condition condition;
        bool isSold;                    // Ended?
    }

    struct Condition {
        uint256 requiredSAT;            // mininum  SAT amount for Buy or Bid 
                                        // 0 SAT, 500 MIL SAT, 1B SAT, 50B SAT, 100B SAT, 500B SAT (0 SAT: not required)
        bool forOnlyV1Holder;           // Only V1 NFT holder can buy or bid
        uint256 v1HolderDiscount;       // Discount percentage for V1 Holder
    }

    struct Bid {
        uint256 itemId;
        address bidder;
        bool isActive;
        uint256 amount;
    }

    mapping(uint256 => Item) public items;
    mapping(address => bool) public isAdmin;
    mapping(uint256 => Bid[]) itemBids;
    
    // percentage of sales
    struct Info {
        address feeAddress;
        address v1NFTAddress;
        address satTokenAddress;

        uint256 royalty;   // default 1%
        uint256 adminFee;  // default 2.5%
    }
    Info public info;

   
    // events 
    event ItemCreated(uint256 itemId);
    event ItemImported(uint256 itemId);
    event BidAddedToItem(address bidder , uint256 itemId , uint256 bidAmount);
    event AuctionCancelled(uint256 itemId);
    event ListCancelled(uint256 itemId);
    event ItemSold(address buyer , uint256 tokenID, uint256 itemId, uint256 amount);
    event UpdatedSupportCurrency(address currency , bool acceptable);

    constructor (address _v1NFT, address _sat, address _fee) ERC721("Saturna NFT" , "SATURNA"){
        info.royalty = 10;
        info.adminFee = 25;

        {
            addSupportedToken(address(0x0));  // BNB
            addSupportedToken(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); // BUSD
            addSupportedToken(_sat); // SAT
        }
        
        info.feeAddress = _fee;
        info.v1NFTAddress = _v1NFT;
        info.satTokenAddress = _sat;
    }


    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _burn(uint256 tokenId) internal virtual override (ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view virtual override (ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual override(ERC721, ERC721Enumerable) { 
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function createItem(
        string memory _uri, 
        uint256 _count,
        uint256 _price,
        bool _auctionable,
        uint256 _startTime,
        uint256 _endTime,
        address _currency,
        uint256 _requiredSAT,
        bool _forOnlyV1Holder,
        uint256 _v1HolderDiscount
    ) external returns (uint256) {
        require(!_auctionable || _count == 1, "can mint only 1 for auctionable item");
        require(_price > 0, "invalid price");
        require(isSupportedToken(_currency), "invalid payment currency");
        require(_v1HolderDiscount < PERCENTS_DIVIDER, "too big discount");

        _itemIds.increment();
        uint256 currentId = _itemIds.current();
        Item storage item = items[currentId];
        
        {
            Condition memory _condition;
            _condition.requiredSAT = _requiredSAT;
            _condition.forOnlyV1Holder = isAdmin[_msgSender()] ? _forOnlyV1Holder : false;
            _condition.v1HolderDiscount = isAdmin[_msgSender()] ? _v1HolderDiscount : 0;

            item.id = currentId;
            item.collection = address(this);
            item.creator = _msgSender();
            item.mintable = true;
            item.uri = _uri;
            item.count = _auctionable ? 1 : _count;
            item.price = _price;
            item.currency = _currency;
            item.auctionable = _auctionable;
            item.startTime = _auctionable ? _startTime : 0;
            item.endTime = _auctionable ? _endTime : 0;
            item.condition = _condition;
            item.isSold = false;
        }

        emit ItemCreated(currentId);
        return currentId;
    }

    function importItem(
        address _collection,
        uint256 _tokenId,
        uint256 _price,
        bool _auctionable,
        uint256 _startTime,
        uint256 _endTime,
        address _currency,
        uint256 _requiredSAT,
        bool _forOnlyV1Holder,
        uint256 _v1HolderDiscount
    ) external returns (uint256) {
        require(_price > 0, "invalid price");
        require(isSupportedToken(_currency), "invalid payment currency");
        require(ERC721(_collection).ownerOf(_tokenId) == _msgSender(), "not owner");
        require(_v1HolderDiscount < PERCENTS_DIVIDER, "too big discount");

        _itemIds.increment();
        uint256 currentId = _itemIds.current();
        Item storage item = items[currentId];
        
        {
            Condition memory _condition;
            _condition.requiredSAT = _requiredSAT;
            _condition.forOnlyV1Holder = isAdmin[_msgSender()] ? _forOnlyV1Holder : false;
            _condition.v1HolderDiscount = isAdmin[_msgSender()] ? _v1HolderDiscount : 0;

            item.id = currentId;
            item.collection = _collection;
            item.tokenId = _tokenId;
            item.creator = _msgSender();
            item.mintable = false;
            item.uri = ERC721URIStorage(_collection).tokenURI(_tokenId);
            item.count = 1;
            item.price = _price;
            item.currency = _currency;
            item.auctionable = _auctionable;
            item.startTime = _auctionable ? _startTime : 0;
            item.endTime = _auctionable ? _endTime : 0;
            item.condition = _condition;
            item.isSold = false;
        }

        emit ItemImported(currentId);
        return currentId;
    }

    function buyItem(uint256 _id, uint256 _amount) external payable nonReentrant {
        _checkCanBuy(_id);

        Item storage item = items[_id];
        uint256 _amountToPay = calcBidAmount(_id, _msgSender(), _amount);

        require(!item.auctionable, "Auctionable sales dont allow outright purchase, place a bid");
        require(_amount == items[_id].price, "Amount below asking price");
        require(item.currency != address(0x0) || _amountToPay == msg.value, "invalid eth value");

        // Process the payment
        _processPayment(_id, _msgSender(), item.price);
        
        uint256 tokenId;
        if(item.mintable) {
            _tokenIds.increment();
            tokenId = _tokenIds.current();
            
            // Mint token directly to buyer
            _safeMint(_msgSender(), tokenId);
            // Set the tokens metadata
            _setTokenURI(tokenId, item.uri);
            // Store creator of item
            _creators[tokenId] = _msgSender();
        } else {
            // Transfer ERC721 to buyer
            tokenId = item.tokenId;
            IERC721(item.collection).safeTransferFrom(address(this), _msgSender(), item.tokenId);
        }
        
        // Reduce available NFTs
        item.count = item.count.sub(1);
        if(item.count == 0) {
            item.isSold = true;
        }

        emit ItemSold(_msgSender(), tokenId,  _id ,  _amount);
    }

    function placeBid(uint256 _id, uint256 _amount) external payable nonReentrant {
        _checkCanBuy(_id);

        Item storage item = items[_id];
        (, uint256 amount ,) = lastBid(_id);
        uint256 _amountToPay = calcBidAmount(_id, _msgSender(), _amount);

        require(item.auctionable , "Not an auctionable sale, purchasse outrightly");
        require(item.currency != address(0x0) || _amount == _amountToPay, "invalid eth value");
        require(_amount > amount && _amount > item.price, "insufficient amount");

        if(item.currency != address(0x0)) {
            // Transfer Payment Token to contract
            require(IERC20(item.currency).transferFrom(_msgSender(), address(this), _amountToPay), "transfer payment token failed");
        }
        
        _refundLastBid(_id);
        
        Bid memory newBid ;
        newBid.itemId = _id;
        newBid.bidder = _msgSender();
        newBid.amount = _amount;
        newBid.isActive = true; 

        itemBids[_id].push(newBid);

        emit BidAddedToItem(_msgSender(), _id , _amount);
    }

    /**
     * Cancel Auction
     */
    function cancelAuction(uint256 _id) public onlyItemCreator(_id) nonReentrant {
        Item storage item =  items[_id];
        require(item.auctionable , "Not an auctionable sale");
        require(!item.isSold, "Item already sold");

        uint256 bidsLength = itemBids[_id].length;

        require(bidsLength == 0, "bid already started");

        // transfer from this contract to item creator
        if(!item.mintable) {
            IERC721(item.collection).safeTransferFrom(address(this), item.creator, item.tokenId);
        }
        
        item.isSold = true;
        item.count = 0;
        emit AuctionCancelled(_id);
    }

    function cancelList(uint256 _id) public onlyItemCreator(_id) {
        Item storage item =  items[_id];
        require(!item.auctionable , "Auctionable sale");
        require(!item.isSold, "Item already sold");
        require(!item.mintable, "Item is mintable");

        // transfer from this contract to item creator
        IERC721(item.collection).safeTransferFrom(address(this), item.creator, item.tokenId);
        
        item.isSold = true;
        item.count = 0;
        emit ListCancelled(_id);
    }
    

    /**
     * @notice Ends the bidding and accepts the winning bid
    */
    function acceptWinningBid(uint256 _id) external onlyItemCreator(_id) nonReentrant {
        require(items[_id].auctionable , "Not an auctionable sale, cancel sales or wait for buyer");
        require(!items[_id].isSold, "Item already sold");
        require(block.timestamp > items[_id].endTime, "auction is running now");

        Item storage item =  items[_id];
        uint256 bidsLength = itemBids[_id].length;
        
        if(bidsLength == 0) {
            cancelAuction(_id);
        } else {
            Bid storage _lastBid = itemBids[_id][bidsLength - 1];

            address buyer = _lastBid.bidder;
            // Process the payment
            uint256 amountToPay = calcBidAmount(_id, _lastBid.bidder, _lastBid.amount);
            _processPayment(_id, address(this),amountToPay);

            uint256 tokenId;
            if(item.mintable) {
                _tokenIds.increment();
                tokenId = _tokenIds.current();
                
                // Mint token directly to buyer
                _safeMint(buyer, tokenId);
                // Set the tokens metadata
                _setTokenURI(tokenId, item.uri);
                // Store creator of item
                _creators[tokenId] =buyer;
            } else {
                // Transfer ERC721 to buyer
                tokenId = item.tokenId;
                IERC721(item.collection).safeTransferFrom(address(this), buyer, item.tokenId);
            }
            
            // Reduce available NFTs
            item.count = item.count.sub(1);
            if(item.count == 0) {
                item.isSold = true;
            }

            emit ItemSold(_msgSender(), tokenId,  _id,  _lastBid.amount);
        }
    }

    /**
     * Check _msgSender() can buy this item
     */
    function _checkCanBuy (uint256 _id) internal view {
        require(_id <= _itemIds.current(), "invalid item id");
        Item memory item = items[_id];

        require(!item.isSold, "item is sold out");
        require(item.count > 0, "Item is sold out");

        if(item.auctionable) {
            require(block.timestamp >= item.startTime, "auction not started yet");
            require(block.timestamp <= item.endTime, "auction is over");
        }

        if(!item.mintable) {
            require(IERC721(item.collection).ownerOf(item.tokenId) == _msgSender(), "insufficient balance");
        }

        require(item.condition.requiredSAT == 0 
            || item.condition.requiredSAT <= IERC20(info.satTokenAddress).balanceOf(_msgSender()), "insufficient $SAT Balance");
        require(!item.condition.forOnlyV1Holder 
            || IERC721(info.v1NFTAddress).balanceOf(_msgSender()) > 0, "require V1 NFT token");
    }

    function _processPayment(uint256 _id, address buyer, uint256 _amount) internal {
        Item memory item = items[_id];
        
        uint256 _total = calcBidAmount(_id, buyer, _amount);
        uint256 _commissionValue = _total.mul(info.adminFee).div(PERCENTS_DIVIDER);
        uint256 _royalties = _total.mul(item.collection == address(this) ? info.royalty : 0).div(PERCENTS_DIVIDER);
        uint256 _sellerValue = _total.sub(_commissionValue).sub(_royalties);
            

        if (item.currency == address(0)) {
            _safeTransferBNB(item.creator, _sellerValue);
            if(_commissionValue > 0) _safeTransferBNB(info.feeAddress, _commissionValue);
            if(_royalties > 0 && _creators[item.tokenId] != address(0x0)) _safeTransferBNB(_creators[item.tokenId], _royalties);
        } else {
            if(buyer == address(this)) {
                IERC20(item.currency).transfer(item.creator, _sellerValue);
                if(_commissionValue > 0)  IERC20(item.currency).transfer(info.feeAddress, _commissionValue);
                if(_royalties > 0 && _creators[item.tokenId] != address(0x0)) 
                    IERC20(item.currency).transfer(_creators[item.tokenId], _royalties);
            } else {
                IERC20(item.currency).transferFrom(buyer, item.creator, _sellerValue);
                if(_commissionValue > 0)  IERC20(item.currency).transferFrom(buyer, info.feeAddress, _commissionValue);
                if(_royalties > 0 && _creators[item.tokenId] != address(0x0)) 
                    IERC20(item.currency).transferFrom(buyer, _creators[item.tokenId], _royalties);
            }
        }
    }


    /**
     * @notice Refunds all other bidders on acceptance of winning bid
    */
    function _refundLastBid(uint256 _id) internal {
        Item memory item =  items[_id];
        uint bidsLength = itemBids[_id].length;
        if(bidsLength > 0) {
            Bid storage _lastBid = itemBids[_id][bidsLength - 1];

            if (_lastBid.isActive && _lastBid.amount > 0 && _lastBid.bidder != address(0)) {
                uint256 amountToRefund = calcBidAmount(_id, _lastBid.bidder,  _lastBid.amount);
                _payoutUser(_lastBid.bidder, item.currency, amountToRefund);
                _lastBid.isActive = false;
            } 
        }
    }

    /**
     * @notice Internal method used for handling external payments
    */
    function _payoutUser(address _recipient , address _currency , uint256 _amount) internal {
        if(_currency == address(0)){
            _safeTransferBNB(_recipient, _amount);
        }else {
            IERC20(_currency).transfer(_recipient , _amount);
        }
    }

    function calcBidAmount(uint256 _id, address _account, uint256 _amount) internal view returns (uint256) {
        Item memory item =  items[_id];
        if(IERC721(info.v1NFTAddress).balanceOf(_account) > 0 && item.condition.v1HolderDiscount > 0) {
            return _amount.mul(PERCENTS_DIVIDER.sub(item.condition.v1HolderDiscount)).div(PERCENTS_DIVIDER);
        } else {
            return _amount;
        }
    }

    function lastBid(uint256 _id) public view returns(address, uint256, bool) {
        if(_id <= _itemIds.current()) {
            uint bidsLength = itemBids[_id].length;
            if(bidsLength > 0) {
                Bid memory _lastBid = itemBids[_id][bidsLength - 1];

                return (_lastBid.bidder, _lastBid.amount, _lastBid.isActive);
            }
        }
        return (address(0x0), 0, false);
    }

    function itemCondition(uint256 _id) public view returns(Condition memory) {
        return items[_id].condition;
    }

    function itemURI(uint256 _id) public view returns(string memory) {
        return items[_id].uri;
    }

    function _safeTransferBNB(address to, uint256 value) internal returns(bool) {
		(bool success, ) = to.call{value: value}(new bytes(0));
		return success;
    }
    
    receive() external payable {}

    /**
        For Admin
     */
    function addSupportedToken(address _address) public onlyOwner {
		_supportedTokens.add(_address);
        emit UpdatedSupportCurrency(_address, true);
    }

    function isSupportedToken(address _address) public view returns (bool) {
        return _supportedTokens.contains(_address);
    }

    function removeSupportedToken(address _address) external onlyOwner {
        _supportedTokens.remove(_address);
        emit UpdatedSupportCurrency(_address, false);
    }

    function supportedTokenAt(uint index) public view returns(address) {
        return _supportedTokens.at(index);
    }

    function supportedTokensLength() public view returns(uint) {
        return _supportedTokens.length();
    }

    function setFeeAddress(address _address) external onlyOwner {
		require(_address != address(0x0), "invalid address");
        info.feeAddress = _address;
    }

	function setFeePercent(uint256 _adminPercent, uint256 _royalty) external onlyOwner {
		require(_adminPercent < FEE_MAX_PERCENT, "too big fee percent");
		require(_royalty < FEE_MAX_PERCENT, "too big fee percent");
		info.adminFee = _adminPercent;
        info.royalty = _royalty;
	}

    function setV1TokenAddress(address _address) external onlyOwner {
		require(_address != address(0x0), "invalid address");
        info.v1NFTAddress = _address;
    }

    function setSATAddress(address _address) external onlyOwner {
		require(_address != address(0x0), "invalid address");
        info.satTokenAddress = _address;
    }

    function addAdmin(address adminAddress) public onlyOwner {
        require(adminAddress != address(0), " admin Address is the zero address");
        isAdmin[adminAddress] = true;
    }

    function removeAdmin(address adminAddress) public onlyOwner {
        require(adminAddress != address(0), " admin Address is the zero address");
        isAdmin[adminAddress] = true;
    }

    modifier onlyAdmin() {
        require( isAdmin[_msgSender()] || owner() == _msgSender(), " caller has no minting right!!!");
        _;
    }
    
    modifier onlyItemCreator(uint256 _id) {
        require(items[_id].creator == _msgSender() || owner() == _msgSender(), "only for item creator");
        _;
    }

}

