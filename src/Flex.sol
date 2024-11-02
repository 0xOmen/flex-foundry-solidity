// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.0 <0.9.0;

// Escrow app using Chainlink or Uniswap oracles to settle contracts on chain
// Users (Maker) can open a bet and another user can take the bet (Taker); Taker can be specified by address
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Context} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

error Flex__BetInWrongStatus();

interface UniV3TwapOracleInterface {
    function convertToHumanReadable(
        address _factory,
        address _token1,
        address _token2,
        uint24 _fee,
        uint32 _twapInterval,
        uint8 _token0Decimals
    ) external view returns (uint256);

    function getToken0(
        address _factory,
        address _tokenA,
        address _tokenB,
        uint24 _fee
    ) external view returns (address);
}

contract Flex is AutomationCompatibleInterface, Context, Ownable {
    using SafeERC20 for IERC20;
    // Global variables
    uint8 private PROTOCOL_FEE;
    address OWNER;
    address UNIV3FACTORY;

    address private UNISWAP_TWAP_LIBRARY;
    UniV3TwapOracleInterface public twapGetter;

    enum Status {
        WAITING_FOR_TAKER,
        KILLED,
        IN_PROCESS,
        MAKER_WINS,
        TAKER_WINS,
        CANCELED,
        MAKER_PAID,
        TAKER_PAID
    }

    enum Comparison {
        GREATER_THAN,
        EQUALS,
        LESS_THAN
    }

    enum OracleType {
        CHAINLINK,
        UNISWAP_V3
    }

    // this struct exists to circumvent Stack too deep errors
    struct BetAddresses {
        address Maker; // stores address of bet creator via msg.sender
        address Taker; // stores address of taker, is either defined by the bet Maker or is blank so anyone can take the bet
        address CollateralToken; // address of the token used as medium of exchange in the bet
        address OracleAddressMain; // address of the Main price oracle that the bet will use (if Uniswap then this is token0)
        address OracleAddress2; // address of a secondary oracle if two are needed (if Uniswap then this is token1)
    }

    // Mapping of mapping to track balances for each token by owner address
    mapping(address => uint256) public ownerTokenBalances;

    // Mapping to track all of a user's bets;
    mapping(address => uint256[]) public UserBets;

    // Universal counter of every bet made
    uint256 public BetNumber;

    // this struct stores bets which will be assigned a BetNumber to be mapped to
    struct Bets {
        BetAddresses betAddresses; // struct to store all bet addresses
        uint BetAmount; // ammount of CollateralToken to be bet with
        uint EndTime; // unix time that bet ends, user defines number of seconds from time the bet creation Tx is approved
        Status BetStatus; // Status of bet as enum: WAITING_FOR_TAKER, KILLED, IN_PROCESS, SETTLED, CANCELED
        OracleType OracleName; // enum defining what type of oracle to use
        uint24 UniswapFeePool; // allows user defined fee pool to get price from ("3000" corresponds to 0.3%)
        uint256 PriceLine; // price level to determine winner based off of the price oracle
        Comparison Comparator; // enum defining direction taken by bet Maker enum: GREATER_THAN, EQUALS, LESS_THAN
        bool MakerCancel; // define if Maker has agreed to cancel bet
        bool TakerCancel; // defines if Taker has agreed to cancel bet
    }

    // Mapping of all opened bets
    mapping(uint256 => Bets) public AllBets;

    //Event triggered when a new bet is offered/created
    event betCreated(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );

    event betTaken(uint256 indexed betNumber); //Event for when a bet recieves a Taker
    event betKilled(uint256 indexed betNumber); //Event for when a bet is killed by the Maker after recieving no Taker
    event betCompleted(
        address indexed winner,
        address indexed loser,
        uint256 indexed betNumber
    ); //Event for when a bet is closed/fulfilled
    //Event for when Maker requests that a bet with a Taker be cancelled
    event attemptBetCancelByMaker(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );
    //Event for when a Taker requests that a bet be cancelled
    event attemptBetCancelByTaker(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );
    //Event for when a bet is cancelled after a Maker and Taker agree
    event betCanceled(uint256 indexed betNumber);

    constructor(
        uint8 _protocolFee,
        address _UNISWAP_TWAP_LIBRARY,
        address _UNIV3FACTORY
    ) Ownable(msg.sender) {
        // Because Solidity can't perform decimal mult/div, multiply by PROTOCOL_FEE and divide by 10,000
        // PROTOCOL_FEE of 0001 equals 0.01% fee
        PROTOCOL_FEE = _protocolFee;
        UNISWAP_TWAP_LIBRARY = _UNISWAP_TWAP_LIBRARY;
        UNIV3FACTORY = _UNIV3FACTORY;
        OWNER = msg.sender;
    }

    function changeProtocolFee(uint8 _newProtocolFee) external onlyOwner {
        PROTOCOL_FEE = _newProtocolFee;
    }

    function getUserBets(
        address _userAddress
    ) external view returns (uint256[] memory) {
        return UserBets[_userAddress];
    }

    function setUniswapOracleLibrary(address _UniLibAddr) external onlyOwner {
        UNISWAP_TWAP_LIBRARY = _UniLibAddr;
        twapGetter = UniV3TwapOracleInterface(UNISWAP_TWAP_LIBRARY);
    }

    function ownerTransferERC20(
        address _tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(
            amount <= ownerTokenBalances[_tokenAddress],
            "Insufficient Funds"
        );
        ownerTokenBalances[_tokenAddress] -= amount;
        IERC20(_tokenAddress).safeTransfer(OWNER, amount);
    }

    function ownerWithdrawEther(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient Funds");
        payable(OWNER).transfer(amount);
    }

    function depositUserTokens(
        address _userAddress,
        address _tokenAddress,
        uint _amount
    ) internal {
        IERC20(_tokenAddress).safeTransferFrom(
            _userAddress,
            address(this),
            _amount
        );
    }

    // Withdraws _amount of tokens if they are avaiable
    function withdrawUserTokens(
        address _userAddress,
        address _tokenAddress,
        uint _amount
    ) internal {
        IERC20(_tokenAddress).safeTransfer(_userAddress, _amount);
    }

    function createNewBet(
        BetAddresses memory _betAddresses,
        uint _amount,
        uint32 _time,
        OracleType _oracleName,
        uint24 _uniFeePool,
        uint256 _priceLine,
        Comparison _comparator
    ) internal {
        AllBets[BetNumber].betAddresses.Maker = _betAddresses.Maker;
        AllBets[BetNumber].betAddresses.Taker = _betAddresses.Taker;
        AllBets[BetNumber].betAddresses.CollateralToken = _betAddresses
            .CollateralToken;
        AllBets[BetNumber].BetAmount = _amount;
        AllBets[BetNumber].EndTime = block.timestamp + _time;
        AllBets[BetNumber].BetStatus = Status.WAITING_FOR_TAKER;

        if (_oracleName == OracleType.UNISWAP_V3) {
            address _token0 = twapGetter.getToken0(
                UNIV3FACTORY,
                _betAddresses.OracleAddressMain,
                _betAddresses.OracleAddress2,
                3000
            );
            if (_betAddresses.OracleAddress2 == _token0) {
                _betAddresses.OracleAddress2 = _betAddresses.OracleAddressMain;
                _betAddresses.OracleAddressMain = _token0;
            }
        }
        AllBets[BetNumber].betAddresses.OracleAddressMain = _betAddresses
            .OracleAddressMain;
        AllBets[BetNumber].betAddresses.OracleAddress2 = _betAddresses
            .OracleAddress2;
        AllBets[BetNumber].OracleName = _oracleName;
        AllBets[BetNumber].PriceLine = _priceLine;
        AllBets[BetNumber].UniswapFeePool = _uniFeePool;
        AllBets[BetNumber].Comparator = _comparator;
        AllBets[BetNumber].MakerCancel = false;
        AllBets[BetNumber].TakerCancel = false;
    }

    function makeBetAndDeposit(
        address _takerAddress,
        address _collateralTokenAddress,
        uint _amount,
        uint32 _time,
        address _oracleAddressMain,
        address _oracleAddress2,
        OracleType _oracleName,
        uint24 _uniFeePool,
        uint256 _priceLine,
        Comparison _comparator
    ) public {
        require(_amount > 0, "amount !> 0");
        require(_takerAddress != msg.sender, "Maker = Taker");
        require(_time > 15, "Time !>15 s");
        BetNumber++;

        BetAddresses memory _betAddresses;
        _betAddresses.Maker = msg.sender;
        _betAddresses.Taker = _takerAddress; // can be 0x0000000000000000000000000000000000000000
        _betAddresses.CollateralToken = _collateralTokenAddress;
        _betAddresses.OracleAddressMain = _oracleAddressMain;
        _betAddresses.OracleAddress2 = _oracleAddress2;
        createNewBet(
            _betAddresses,
            _amount,
            _time,
            _oracleName,
            _uniFeePool,
            _priceLine,
            _comparator
        );

        UserBets[msg.sender].push(BetNumber);
        emit betCreated(_betAddresses.Maker, _betAddresses.Taker, BetNumber);
        depositUserTokens(msg.sender, _collateralTokenAddress, _amount);
    }

    function cancelBet(uint _betNumber) public {
        Bets memory _targetBet = AllBets[_betNumber];
        // Check that request was sent by bet Maker
        require(msg.sender == _targetBet.betAddresses.Maker, "!Maker");
        // check that bet is not taken
        require(_targetBet.BetStatus == Status.WAITING_FOR_TAKER, "Status");
        // Change status to "KILLED"
        AllBets[_betNumber].BetStatus = Status.KILLED;
        // subtract the bet amount from escrowedBalance
        emit betKilled(_betNumber);
        withdrawUserTokens(
            _targetBet.betAddresses.Maker,
            _targetBet.betAddresses.CollateralToken,
            _targetBet.BetAmount
        );
    }

    function takeBetAndDeposit(uint _betNumber) public {
        Bets memory _targetBet = AllBets[_betNumber];
        //check if msg.sender can be taker
        require(
            msg.sender == _targetBet.betAddresses.Taker ||
                _targetBet.betAddresses.Taker == address(0),
            "!Taker"
        );
        // require that the bet is not taken, killed, cancelled, or completed
        require(_targetBet.BetStatus == Status.WAITING_FOR_TAKER, "Status");
        // require bet time not passed
        require(_targetBet.EndTime > block.timestamp, "Action expired");

        // Assign msg.sender to Taker if Taker is unassigned
        if (AllBets[_betNumber].betAddresses.Taker == address(0)) {
            AllBets[_betNumber].betAddresses.Taker = msg.sender;
        }

        AllBets[_betNumber].BetStatus = Status.IN_PROCESS;
        UserBets[msg.sender].push(_betNumber);
        emit betTaken(_betNumber);
        depositUserTokens(
            msg.sender,
            _targetBet.betAddresses.CollateralToken,
            _targetBet.BetAmount
        );
    }

    function closeBet(uint _betNumber) public {
        // check _betNumber exists
        require(_betNumber <= BetNumber, "This bet does not exist");
        Bets memory _targetBet = AllBets[_betNumber];
        // check bet for correct status and time
        require(checkClosable(_betNumber), "Status or Time");

        // check winner
        bool makerWins;
        uint256 currentPrice = getOraclePriceByBet(_betNumber);
        uint256 priceLine = _targetBet.PriceLine;

        if (currentPrice > priceLine) {
            if (_targetBet.Comparator == Comparison.GREATER_THAN) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        } else if (currentPrice < priceLine) {
            if (_targetBet.Comparator == Comparison.LESS_THAN) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        } else {
            if (_targetBet.Comparator == Comparison.EQUALS) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        }

        if (makerWins) {
            AllBets[_betNumber].BetStatus = Status.MAKER_WINS;
            emit betCompleted(
                _targetBet.betAddresses.Maker,
                _targetBet.betAddresses.Taker,
                _betNumber
            );
        } else {
            AllBets[_betNumber].BetStatus = Status.TAKER_WINS;
            emit betCompleted(
                _targetBet.betAddresses.Taker,
                _targetBet.betAddresses.Maker,
                _betNumber
            );
        }
    }

    function settleBet(uint _betNumber) public {
        Bets memory _targetBet = AllBets[_betNumber];
        // check bet status
        if (
            !(_targetBet.BetStatus == Status.MAKER_WINS ||
                _targetBet.BetStatus == Status.TAKER_WINS)
        ) {
            revert Flex__BetInWrongStatus();
        }

        address _winningAddress;
        address _losingAddress;
        address _collateralToken = _targetBet.betAddresses.CollateralToken;

        if (_targetBet.BetStatus == Status.MAKER_WINS) {
            AllBets[_betNumber].BetStatus = Status.MAKER_PAID;
            _winningAddress = AllBets[_betNumber].betAddresses.Maker;
            _losingAddress = AllBets[_betNumber].betAddresses.Taker;
        } else {
            _targetBet.BetStatus = Status.TAKER_PAID;
            _winningAddress = AllBets[_betNumber].betAddresses.Taker;
            _losingAddress = AllBets[_betNumber].betAddresses.Maker;
        }

        uint256 payoutAmount = ((2 * _targetBet.BetAmount) *
            (10000 - PROTOCOL_FEE)) / 10000;
        withdrawUserTokens(_winningAddress, _collateralToken, payoutAmount);
        ownerTokenBalances[_collateralToken] +=
            (2 * _targetBet.BetAmount) -
            payoutAmount;
    }

    function requestBetCancel(uint _betNumber) public {
        Bets memory _targetBet = AllBets[_betNumber];
        // Require that request was sent by Maker or Taker
        require(
            msg.sender == _targetBet.betAddresses.Maker ||
                msg.sender == _targetBet.betAddresses.Taker,
            "!Maker/Taker"
        );
        // Require that bet is in a cancellable state ("IN_PROCESS")
        require(_targetBet.BetStatus == Status.IN_PROCESS, "Status");

        if (msg.sender == _targetBet.betAddresses.Maker) {
            AllBets[_betNumber].MakerCancel = true;
            emit attemptBetCancelByMaker(
                _targetBet.betAddresses.Maker,
                _targetBet.betAddresses.Taker,
                _betNumber
            );
        } else if (msg.sender == _targetBet.betAddresses.Taker) {
            AllBets[_betNumber].TakerCancel = true;
            emit attemptBetCancelByTaker(
                _targetBet.betAddresses.Maker,
                _targetBet.betAddresses.Taker,
                _betNumber
            );
        }

        //If Maker and Taker agree to cancel then refund each their tokens
        if (
            AllBets[_betNumber].MakerCancel == true &&
            AllBets[_betNumber].TakerCancel == true
        ) {
            emit betCanceled(_betNumber);
            AllBets[_betNumber].BetStatus = Status.CANCELED;
            withdrawUserTokens(
                _targetBet.betAddresses.Maker,
                _targetBet.betAddresses.CollateralToken,
                _targetBet.BetAmount
            );
            withdrawUserTokens(
                _targetBet.betAddresses.Taker,
                _targetBet.betAddresses.CollateralToken,
                _targetBet.BetAmount
            );
        }
    }

    function checkClosable(uint _betNumber) public view returns (bool) {
        if (
            block.timestamp >= AllBets[_betNumber].EndTime &&
            AllBets[_betNumber].BetStatus == Status.IN_PROCESS
        ) {
            return true;
        } else {
            return false;
        }
    }

    function getDecimals(address _oracleAddress) public view returns (uint8) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_oracleAddress);
        return priceFeed.decimals();
    }

    function getChainlinkPrice(
        address _oracleAddress
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_oracleAddress);
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        return uint256(answer / int256(10 ** getDecimals(_oracleAddress)));
    }

    function getOraclePriceByBet(
        uint256 _betNumber
    ) public view returns (uint256) {
        Bets memory _targetBet = AllBets[_betNumber];
        uint256 CurrentPrice;
        if (_targetBet.OracleName == OracleType.CHAINLINK) {
            if (_targetBet.betAddresses.OracleAddress2 == address(0)) {
                CurrentPrice = getChainlinkPrice(
                    _targetBet.betAddresses.OracleAddressMain
                );
            } else {
                CurrentPrice =
                    getChainlinkPrice(
                        _targetBet.betAddresses.OracleAddressMain
                    ) /
                    getChainlinkPrice(_targetBet.betAddresses.OracleAddress2);
            }
        } else if (_targetBet.OracleName == OracleType.UNISWAP_V3) {
            uint8 _token0Decimals = ERC20(
                _targetBet.betAddresses.OracleAddressMain
            ).decimals();
            // address _factory, address _token1, address _token2, uint24 _fee, uint32 _twapInterval, uint8 _decimals
            CurrentPrice = twapGetter.convertToHumanReadable(
                UNIV3FACTORY,
                _targetBet.betAddresses.OracleAddressMain,
                _targetBet.betAddresses.OracleAddress2,
                _targetBet.UniswapFeePool,
                uint32(60),
                _token0Decimals
            );
        }
        return CurrentPrice;
    }

    function checkUpkeep(
        bytes calldata /* checkData*/
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256[] memory betsToClose = new uint[](10);
        uint arrayIndex = 0;
        //go through AllBets and if any are closable: add bet Number to needsClose, set upkeepNeeded to true
        for (uint _betNumber = 1; _betNumber <= BetNumber; _betNumber++) {
            if (checkClosable(_betNumber)) {
                betsToClose[arrayIndex] = _betNumber;
                upkeepNeeded = true;
                arrayIndex++;
            }
            if (arrayIndex == 10) {
                _betNumber += BetNumber;
            }
        }

        performData = abi.encode(betsToClose);
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory needsClosed = abi.decode(performData, (uint256[]));
        for (
            uint betInArray = 0;
            betInArray < needsClosed.length;
            betInArray++
        ) {
            if (needsClosed[betInArray] == 0) break;
            if (checkClosable(needsClosed[betInArray]))
                closeBet(needsClosed[betInArray]);
        }
    }
}
