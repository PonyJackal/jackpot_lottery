// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IJackpotLotteryTicket.sol";
import "./interfaces/IChainlinkAggregator.sol";

contract JackpotLottery is Ownable {
    using Address for address;

    IJackpotLotteryTicket internal ticket;
    IChainlinkAggregator internal chainlinkAggregator;
    IERC20 public myToken;

    enum Status {
        NotStarted,
        Open,
        Closed,
        Completed
    }

    //TODO; add timestamp
    //TODO; add rewards

    string public myTokenId; // coingecko token id
    uint256 public myTokenPrice;
    uint256 internal myTokenPriceLastUpdated;

    uint256 public index;
    uint256 internal requestId;
    bytes32 internal priceRequestId;

    struct LotteryInfo {
        uint256 lotteryId;
        // token info
        address token;
        uint256 tokenPrice;
        uint256 priceLastUpdatedTime;
        string tokenId; // coingecko token id
        Status status;
        uint256 ticketPrice; // USD
        uint256 startTime;
        uint256 endTime;
        uint256[] prizePool; // 0: BNB, 1: myToken, 2: Partner token
        //TOOD; check current balance of prize pool
        uint16[] winningNumbers;
    }

    // id => LotteryInfo mapping
    mapping(uint256 => LotteryInfo) internal lotteries;

    uint256 public constant PRICE = 1 ether;
    uint256 public constant TICKET_SALE_END_DUE = 30 minutes;
    uint8 public constant SIZE_OF_NUMBER = 6;
    // How long will the contract assume rate update is not needed
    uint256 public constant RATE_FRESH_PERIOD = 1 hours;

    //-------------------------------------------------------------------------
    // EVENTS
    //-------------------------------------------------------------------------

    event TicketUpdated(address ticket);
    event TokenUpdated(address token, string tokenId);
    event ChainlinkAggregatorUpdated(address chainlinkAggregator);

    event NewLotteryCreated(
        uint256 indexed lotteryId,
        address indexed owner,
        address token,
        uint256 ticketPrice,
        uint256 startTime,
        uint256 endTime
    );
    event TicketBought(uint256 indexed lotteryId, address indexed owner, uint8 indexed buyType, uint8 numberOfTickets);
    event TicketsClaimed(uint256 indexed lotteryId, uint256[] ticketIds);

    event WinningNumberRevealed(uint256 indexed lotteryId, uint16[] winningNumbers);

    /** CONSTRUCTOR */
    constructor(
        address _token,
        string memory _tokenId,
        address _ticket,
        address _chainlinkAggregator
    ) {
        require(_token != address(0), "Invalid token address");
        require(_ticket != address(0), "Invalid ticket address");
        require(_chainlinkAggregator != address(0), "Invalid chainlinkAggregator address");

        myToken = IERC20(_token);
        myTokenId = _tokenId;
        ticket = IJackpotLotteryTicket(_ticket);
        chainlinkAggregator = IChainlinkAggregator(_chainlinkAggregator);
        //request price update
        priceRequestId = chainlinkAggregator.requestCryptoPrice(0, _tokenId);
    }

    /** MODIFIERS */
    modifier notContract() {
        require(!address(msg.sender).isContract(), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    modifier onlyChainlinkAggregator() {
        require(msg.sender == address(chainlinkAggregator), "Not a chainlinkAggregator");
        _;
    }

    /** SETTER FUNCTIONS */
    /**
     * @dev update ticket contract
     * @param _ticket new ticket address
     */
    function setTicket(address _ticket) external onlyOwner {
        require(_ticket != address(0), "Invalid ticket address");
        ticket = IJackpotLotteryTicket(_ticket);
        emit TicketUpdated(_ticket);
    }

    /**
     * @dev update token contract
     * @param _token new token address
     * @param _tokenId new tokenId
     */
    function setToken(address _token, string memory _tokenId) external onlyOwner {
        require(_token != address(0), "Invalid ticket address");
        myToken = IERC20(_token);
        myTokenId = _tokenId;
        //request price update
        priceRequestId = chainlinkAggregator.requestCryptoPrice(0, _tokenId);
        emit TokenUpdated(_token, _tokenId);
    }

    /**
     * @dev update chainlinkAggregator contract
     * @param _chainlinkAggregator new chainlinkAggregator address
     */
    function setChainlinkAggregator(address _chainlinkAggregator) external onlyOwner {
        require(_chainlinkAggregator != address(0), "Invalid chainlink address");
        chainlinkAggregator = IChainlinkAggregator(_chainlinkAggregator);
        emit ChainlinkAggregatorUpdated(_chainlinkAggregator);
    }

    /** EXTERNAL FUNCTIONS */
    /**
     * @dev create a new lottery, users need to pay 1 BNB
     * @param _token partner token address
     * @param _tokenId partner tokenId on coingecko
     * @param _ticketPrice ticket price in usd
     * @param _startTime lottery start time
     * @param _endTime lottery end time
     */
    function creatLottery(
        address _token,
        string memory _tokenId,
        uint256 _ticketPrice,
        uint256 _startTime,
        uint256 _endTime
    ) external payable notContract {
        require(_token != address(0), "Invalid token address");
        require(msg.value >= PRICE, "Insufficient fee");
        require(_startTime < _endTime, "Invalid start and end time");

        // refund
        refundIfOver(PRICE);
        // lottery id starts from 1
        index++;
        Status lotteryStatus;
        if (_startTime >= block.timestamp) {
            lotteryStatus = Status.Open;
        } else {
            lotteryStatus = Status.NotStarted;
        }
        uint16[] memory winningNumbers = new uint16[](SIZE_OF_NUMBER);
        uint256[] memory prizePool = new uint256[](3);
        LotteryInfo memory lottery = LotteryInfo(
            index,
            _token,
            0,
            0,
            _tokenId,
            Status.Open,
            _ticketPrice,
            _startTime,
            _endTime,
            prizePool,
            winningNumbers
        );
        // request token price update
        priceRequestId = chainlinkAggregator.requestCryptoPrice(index, _tokenId);
        lotteries[index] = lottery;

        emit NewLotteryCreated(index, msg.sender, _token, _ticketPrice, _startTime, _endTime);
    }

    /**
     * @dev batch buy a ticket with BNB
     * @param _lotteryId lottery id to buy
     * @param _numOfTickets number of tickets to buy
     * @param _nums numbers user put in the tickets
     */
    function buyTicketWithBNB(
        uint256 _lotteryId,
        uint8 _numOfTickets,
        uint16[] memory _nums
    ) external payable notContract {
        buyTicketValidation(_lotteryId, _numOfTickets, _nums);

        LotteryInfo memory lottery = lotteries[_lotteryId];
        // calculate BNB amount
        (uint256 reserve0, uint256 reserve1) = chainlinkAggregator.getBNBPrice();
        uint256 amount = (lottery.ticketPrice * reserve0 * 10**18) / reserve1;
        require(msg.value >= amount * _numOfTickets, "Insufficient amount");
        // refund
        refundIfOver(amount * _numOfTickets);
        // increase prize pool for BNB
        lotteries[_lotteryId].prizePool[0] += amount * _numOfTickets;
        // mint tickets
        ticket.batchMint(msg.sender, lottery.lotteryId, _numOfTickets, _nums);

        emit TicketBought(_lotteryId, msg.sender, 0, _numOfTickets);
    }

    /**
     * @dev batch buy a ticket with my token
     * @param _lotteryId lottery id to buy
     * @param _numOfTickets number of tickets to buy
     * @param _nums numbers user put in the tickets
     */
    function buyTicketWithMyToken(
        uint256 _lotteryId,
        uint8 _numOfTickets,
        uint16[] memory _nums
    ) external notContract {
        buyTicketValidation(_lotteryId, _numOfTickets, _nums);
        LotteryInfo memory lottery = lotteries[_lotteryId];
        require(myTokenPrice != 0, "My Token price is not set");
        // if price is not fresh, request price update
        if (myTokenPriceLastUpdated <= (block.timestamp - RATE_FRESH_PERIOD)) {
            priceRequestId = chainlinkAggregator.requestCryptoPrice(0, myTokenId);
        }
        uint256 tokenPerTicket = (lottery.ticketPrice * 10**18) / myTokenPrice / 10**18;
        myToken.transferFrom(msg.sender, address(this), tokenPerTicket * _numOfTickets);
        // increase prize pool for MyToken
        lotteries[_lotteryId].prizePool[1] += tokenPerTicket * _numOfTickets;
        // mint tickets
        ticket.batchMint(msg.sender, lottery.lotteryId, _numOfTickets, _nums);

        emit TicketBought(_lotteryId, msg.sender, 1, _numOfTickets);
    }

    /**
     * @dev batch buy a ticket with partner token
     * @param _lotteryId lottery id to buy
     * @param _numOfTickets number of tickets to buy
     * @param _nums numbers user put in the tickets
     */
    function buyTicketWithPartnerToken(
        uint256 _lotteryId,
        uint8 _numOfTickets,
        uint16[] memory _nums
    ) external notContract {
        buyTicketValidation(_lotteryId, _numOfTickets, _nums);
        LotteryInfo memory lottery = lotteries[_lotteryId];
        require(lottery.tokenPrice != 0, "Partner Token price is not set");
        // if price is not fresh, request price update
        if (lottery.priceLastUpdatedTime <= (block.timestamp - RATE_FRESH_PERIOD)) {
            priceRequestId = chainlinkAggregator.requestCryptoPrice(_lotteryId, lottery.tokenId);
        }
        uint256 tokenPerTicket = (lottery.ticketPrice * 10**18) / lottery.tokenPrice / 10**18;
        IERC20(lottery.token).transferFrom(msg.sender, address(this), tokenPerTicket * _numOfTickets);
        // increase prize pool for Partner Token
        lotteries[_lotteryId].prizePool[2] += tokenPerTicket * _numOfTickets;
        // mint tickets
        ticket.batchMint(msg.sender, lottery.lotteryId, _numOfTickets, _nums);

        emit TicketBought(_lotteryId, msg.sender, 2, _numOfTickets);
    }

    /**
     * @dev users claim rewards for their ticket
     * @param _lotteryId lottery id to claim
     * @param _ticketIds ticket ids to claim
     */
    function claimRewards(uint256 _lotteryId, uint256[] calldata _ticketIds) external notContract {
        LotteryInfo memory lottery = lotteries[_lotteryId];
        require(block.timestamp >= lottery.endTime, "Lottery is not end yet");
        require(lottery.status == Status.Completed, "Winning numbers are not revealed yet");
        uint256[] memory numOfWinners = ticket.getNumOfWinners(_lotteryId);
        uint8[5] memory percentagesPerMatches = [35, 15, 10, 10, 30];
        uint256 precision = 10**18;

        for (uint256 i = 0; i < _ticketIds.length; i++) {
            require(ticket.getOwnerOfTicket(_ticketIds[i]) == msg.sender, "Invalid owner");
            if (!ticket.getStatusOfTicket(_ticketIds[i])) {
                require(ticket.claimTicket(_ticketIds[i], _lotteryId), "Invalid ticket numbers");
                uint8 numOfMatches = _findMatches(ticket.getTicketNumer(_ticketIds[i]), lottery.winningNumbers);
                if (numOfMatches > 1) {
                    uint256 percent = (percentagesPerMatches[numOfMatches - 2] * precision) /
                        numOfWinners[numOfMatches - 2];
                    address payable owner = payable(ticket.getOwnerOfTicket(_ticketIds[i]));
                    // transfer BNB to winner
                    uint256 bnbPrize = (lottery.prizePool[0] * percent) / precision / 10**2;
                    owner.transfer(bnbPrize);
                    // transfer myToken to winner
                    uint256 myTokenPrize = (lottery.prizePool[1] * percent) / precision / 10**2;
                    myToken.transferFrom(address(this), owner, myTokenPrize);
                    // transfer PartnerToken to winner
                    uint256 partnerTokenPrize = (lottery.prizePool[2] * percent) / precision / 10**2;
                    IERC20(lottery.token).transferFrom(address(this), owner, partnerTokenPrize);
                }
            }
        }

        emit TicketsClaimed(_lotteryId, _ticketIds);
    }

    /** CALLBACK FUNCTIONS */
    /**
     * @dev chainlinkAggregator callback function to reveal random number
     * @param _lotteryId lottery id
     * @param _requestId chainlink request id
     * @param _randomNumber random number
     */
    function revealRandomNumbers(
        uint256 _lotteryId,
        uint256 _requestId,
        uint256 _randomNumber
    ) external onlyChainlinkAggregator {
        require(lotteries[_lotteryId].status == Status.Closed, "Lottery is not closed");
        require(requestId == _requestId, "Invalid request");

        lotteries[_lotteryId].status = Status.Closed;
        lotteries[_lotteryId].winningNumbers = _splitNumber(_randomNumber);
        // calculate winner counts
        ticket.countWinners(_lotteryId, lotteries[_lotteryId].winningNumbers);
        emit WinningNumberRevealed(_lotteryId, lotteries[_lotteryId].winningNumbers);
    }

    /**
     * @dev chainlinkAggregator callback function to update token price
     * @param _requestId chainlink request id
     * @param _lotteryId lottery id
     * @param _price token price
     */
    function updateTokenPrice(
        bytes32 _requestId,
        uint256 _lotteryId,
        uint256 _price
    ) external onlyChainlinkAggregator {
        require(priceRequestId == _requestId, "Invalid request");

        if (_lotteryId != 0) {
            lotteries[_lotteryId].tokenPrice = _price;
            lotteries[_lotteryId].priceLastUpdatedTime = block.timestamp;
        } else {
            myTokenPrice = _price;
            myTokenPriceLastUpdated = block.timestamp;
        }
    }

    /** INTERNAL FUNCTIONS */
    function _splitNumber(uint256 _randomNumber) internal pure returns (uint16[] memory) {
        uint16[] memory winningNumbers = new uint16[](SIZE_OF_NUMBER);

        for (uint8 i = 0; i < SIZE_OF_NUMBER; i++) {
            bytes32 hashOfRandom = keccak256(abi.encodePacked(_randomNumber, i));
            uint256 numberRepresentation = uint256(hashOfRandom);
            winningNumbers[i] = uint16(numberRepresentation % 10);
        }
        return winningNumbers;
    }

    function _findMatches(uint16[] memory _numbers, uint16[] memory _winningNumbers) internal pure returns (uint8) {
        uint8 numOfMatches;
        for (uint8 i = 0; i < SIZE_OF_NUMBER; i++) {
            if (_numbers[i] == _winningNumbers[i]) {
                numOfMatches++;
            }
        }
        return numOfMatches;
    }

    function buyTicketValidation(
        uint256 _lotteryId,
        uint8 _numOfTickets,
        uint16[] memory _nums
    ) internal {
        //TODO; add more validations
        require(block.timestamp <= (lotteries[_lotteryId].endTime - TICKET_SALE_END_DUE), "Ticket sale ended");
        uint256 numCheck = SIZE_OF_NUMBER * _numOfTickets;
        require(_nums.length == numCheck, "Invalid numbers");
        // check lottery status
        if (lotteries[_lotteryId].status == Status.NotStarted && lotteries[_lotteryId].startTime >= block.timestamp) {
            lotteries[_lotteryId].status = Status.Open;
        }
        require(lotteries[_lotteryId].status == Status.Open, "Lottery is not started");
    }

    /** PRIVATE FUNCTIONS */
    function refundIfOver(uint256 _price) private {
        if (msg.value > _price) {
            payable(msg.sender).transfer(msg.value - _price);
        }
    }
}
