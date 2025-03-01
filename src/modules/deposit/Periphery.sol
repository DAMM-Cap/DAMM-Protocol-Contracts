// SPDX-License-Identifier: CC-BY-NC-4.0

pragma solidity ^0.8.0;

import "@solmate/tokens/ERC20.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "@openzeppelin-contracts/utils/math/SignedMath.sol";
import "@openzeppelin-contracts/utils/math/SafeCast.sol";
import "@solady/utils/FixedPointMathLib.sol";
import "@src/libs/Constants.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesKeyedUpgradeable.sol";
import "@src/libs/Errors.sol";
import "@zodiac/interfaces/IAvatar.sol";
import "@src/interfaces/IPeriphery.sol";
import "./UnitOfAccount.sol";
import {FundShareVault} from "./FundShareVault.sol";
import {DepositLibs} from "./DepositLibs.sol";
import {SafeLib} from "@src/libs/SafeLib.sol";
import {IPermit2} from "@permit2/src/interfaces/IPermit2.sol";
import "@zodiac/factory/FactoryFriendly.sol";
import "@src/interfaces/IPeriphery.sol";
import "@src/interfaces/IDepositModule.sol";
import "@openzeppelin-contracts/utils/cryptography/EIP712.sol";

/// @title Periphery
/// @notice Manages deposits, withdrawals, and brokerage accounts for a Fund
/// @dev Each Periphery is paired with exactly one Fund and manages ERC721 tokens representing brokerage accounts.
///      The Periphery handles:
///      - Asset deposits/withdrawals through the DepositModule
///      - Broker account management (NFTs)
///      - Fee collection and distribution
contract Periphery is
    EIP712,
    FactoryFriendly,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    NoncesKeyedUpgradeable,
    IPeriphery
{
    using DepositLibs for BrokerAccountInfo;
    using DepositLibs for address;
    using DepositLibs for ERC20;
    using DepositLibs for DepositIntent;
    using DepositLibs for WithdrawIntent;
    using SafeTransferLib for ERC20;

    using SafeLib for IAvatar;
    using SafeCast for uint256;
    using SignedMath for int256;
    using FixedPointMathLib for uint256;

    /// @dev The permit2 contract
    address public immutable permit2;

    /// @dev The deposit module for the fund
    IDepositModule public depositModule;

    /// @dev The recipient of the protocol fees
    address public protocolFeeRecipient;
    /// @dev Timestamp of the last management fee collection
    uint256 private lastManagementFeeTimestamp;
    /// @dev The management fee rate in basis points
    uint256 public managementFeeRateInBps;

    /// @dev Maps token IDs to their brokerage account information
    mapping(uint256 tokenId => Broker broker) private brokers;

    /// @dev Counter for brokerage account token IDs
    uint256 private tokenId = 0;

    /// @dev Constructor for the Periphery contract
    /// @param permit2_ The address of the permit2 contract
    constructor(address permit2_, string memory version_) EIP712("DAMM Periphery", version_) {
        permit2 = permit2_;
    }

    /// @notice Initializes the Periphery contract
    /// @param initializeParams Encoded parameters for the Periphery contract
    function setUp(bytes memory initializeParams) public override initializer {
        /// @dev vaultName_ Name of the Brokerage NFT
        /// @dev vaultSymbol_ Symbol of the Brokerage NFT
        /// @dev owner_ Address that owns the Periphery
        /// @dev minter_ Address with minting privileges
        /// @dev depositModule_ Address of the deposit module
        /// @dev protocolFeeRecipient_ Address that receives protocol fees
        (
            string memory brokerNftName_,
            string memory brokerNftSymbol_,
            address owner_,
            address minter_,
            address controller_,
            address depositModule_,
            address protocolFeeRecipient_
        ) = abi.decode(
            initializeParams, (string, string, address, address, address, address, address)
        );
        if (owner_ == address(0)) {
            revert Errors.Deposit_InvalidConstructorParam();
        }
        if (minter_ == address(0)) {
            revert Errors.Deposit_InvalidConstructorParam();
        }
        if (depositModule_ == address(0)) {
            revert Errors.Deposit_InvalidConstructorParam();
        }
        if (protocolFeeRecipient_ == address(0)) {
            revert Errors.Deposit_InvalidConstructorParam();
        }

        _transferOwnership(owner_);
        __NoncesKeyed_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __ERC721_init(brokerNftName_, brokerNftSymbol_);

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(ACCOUNT_MANAGER_ROLE, minter_);
        _grantRole(CONTROLLER_ROLE, controller_);

        depositModule = IDepositModule(depositModule_);
        protocolFeeRecipient = protocolFeeRecipient_;
        lastManagementFeeTimestamp = block.timestamp;

        emit PeripherySetup(msg.sender, owner_, depositModule_, controller_, protocolFeeRecipient_);
    }

    /// @dev this modifier ensures that the account info is zeroed out if the broker has no shares outstanding
    modifier zeroOutAccountInfo(uint256 accountId_) {
        _;
        if (brokers[accountId_].account.totalSharesOutstanding == 0) {
            brokers[accountId_].account.cumulativeSharesMinted = 0;
            brokers[accountId_].account.cumulativeUnitsDeposited = 0;
        }
    }

    modifier checkOrderDeadline(uint256 deadline_) {
        if (deadline_ < block.timestamp) {
            revert Errors.Deposit_OrderExpired();
        }
        _;
    }

    /// @inheritdoc IPeriphery
    function intentDeposit(SignedDepositIntent calldata order)
        public
        whenNotPaused
        nonReentrant
        checkOrderDeadline(order.intent.deposit.deadline)
        returns (uint256 sharesOut)
    {
        (Broker storage broker, address minter) = _getBrokerOrRevert(order.intent.deposit.accountId);

        if (!broker.account.isPublic && order.intent.deposit.minter != minter) {
            revert Errors.Deposit_OnlyAccountOwner();
        }

        _validateBrokerAssetPolicy(order.intent.deposit.asset, broker, true);

        /// consume nonce. get back keyNonce.
        uint256 keyNonce =
            _useNonce(order.intent.deposit.minter, uint192(order.intent.deposit.accountId));

        DepositLibs.validateIntent(
            _hashTypedDataV4(order.intent.hashDepositIntent()),
            order.signature,
            order.intent.deposit.minter,
            order.intent.chainId,
            keyNonce,
            order.intent.nonce
        );

        /// @notice The management fee should be charged before the deposit is processed
        /// otherwise, the management fee will be charged on the deposit amount
        _takeManagementFee();

        uint256 assetAmountIn = order.intent.deposit.amount == type(uint256).max
            ? ERC20(order.intent.deposit.asset).balanceOf(order.intent.deposit.minter)
            : order.intent.deposit.amount + order.intent.relayerTip + order.intent.bribe;

        if (assetAmountIn < order.intent.bribe + order.intent.relayerTip) {
            revert Errors.Deposit_InsufficientAmount();
        }

        /// transfer the net amount in from the broker to the periphery
        IPermit2(permit2).transferFrom(
            order.intent.deposit.minter,
            address(this),
            uint160(assetAmountIn),
            order.intent.deposit.asset
        );

        ERC20 assetToken = ERC20(order.intent.deposit.asset);

        /// pay the bribe to the fund if required
        assetToken.pay(depositModule.fund(), order.intent.bribe);

        /// pay the relayer if required
        assetToken.pay(msg.sender, order.intent.relayerTip);

        assetAmountIn -= order.intent.relayerTip + order.intent.bribe;

        sharesOut = _deposit(
            broker,
            broker.account,
            order.intent.deposit.accountId,
            order.intent.deposit.asset,
            assetAmountIn,
            order.intent.deposit.recipient,
            order.intent.deposit.minSharesOut
        );
    }

    /// @inheritdoc IPeriphery
    function deposit(DepositOrder calldata order)
        public
        whenNotPaused
        nonReentrant
        checkOrderDeadline(order.deadline)
        returns (uint256 sharesOut)
    {
        (Broker storage broker, address minter) = _getBrokerOrRevert(order.accountId);

        if (!broker.account.isPublic && (minter != msg.sender && minter != order.minter)) {
            revert Errors.Deposit_OnlyAccountOwner();
        }

        /// @notice The management fee should be charged before the deposit is processed
        /// otherwise, the management fee will be charged on the deposit amount
        _takeManagementFee();

        _validateBrokerAssetPolicy(order.asset, broker, true);

        uint256 assetAmountIn = order.amount == type(uint256).max
            ? ERC20(order.asset).balanceOf(order.minter)
            : order.amount;

        /// transfer the net amount in from the broker to the periphery
        IPermit2(permit2).transferFrom(
            order.minter, address(this), uint160(assetAmountIn), order.asset
        );

        sharesOut = _deposit(
            broker,
            broker.account,
            order.accountId,
            order.asset,
            assetAmountIn,
            order.recipient,
            order.minSharesOut
        );
    }

    function _deposit(
        Broker storage broker,
        BrokerAccountInfo memory accountInfo,
        uint256 accountId,
        address asset,
        uint256 assetAmountIn,
        address recipient,
        uint256 minSharesOut
    ) private returns (uint256) {
        /// mint shares to the periphery using the liquidity that was just minted
        (uint256 sharesOut, uint256 liquidity) =
            depositModule.deposit(asset, assetAmountIn, minSharesOut, address(this));

        /// make sure the broker hasn't exceeded their share mint limit
        if (accountInfo.totalSharesOutstanding + sharesOut > accountInfo.shareMintLimit) {
            revert Errors.Deposit_ShareMintLimitExceeded();
        }

        /// update the broker's cumulative units deposited
        broker.account.cumulativeUnitsDeposited += liquidity;

        /// update the broker's total shares outstanding
        broker.account.totalSharesOutstanding += sharesOut;

        /// update the broker's cumulative shares minted
        broker.account.cumulativeSharesMinted += sharesOut;

        uint256 netBrokerFee =
            sharesOut.fullMulDivUp(accountInfo.brokerEntranceFeeInBps, BP_DIVISOR);
        uint256 netProtocolFee =
            sharesOut.fullMulDivUp(accountInfo.protocolEntranceFeeInBps, BP_DIVISOR);

        sharesOut -= netBrokerFee + netProtocolFee;

        ERC20 shareToken = ERC20(depositModule.getVault());

        /// transfer assets to the broker, protocol, and recipient
        shareToken.pay(recipient, sharesOut);
        shareToken.pay(accountInfo.feeRecipient, netBrokerFee);
        shareToken.pay(protocolFeeRecipient, netProtocolFee);

        emit Deposit(accountId, recipient, sharesOut, netBrokerFee, netProtocolFee);

        return sharesOut;
    }

    function intentWithdraw(SignedWithdrawIntent calldata order)
        public
        whenNotPaused
        nonReentrant
        checkOrderDeadline(order.intent.withdraw.deadline)
        zeroOutAccountInfo(order.intent.withdraw.accountId)
        returns (uint256)
    {
        (Broker storage broker, address burner) =
            _getBrokerOrRevert(order.intent.withdraw.accountId);

        if (!broker.account.isPublic && order.intent.withdraw.burner != burner) {
            revert Errors.Deposit_OnlyAccountOwner();
        }

        _validateBrokerAssetPolicy(order.intent.withdraw.asset, broker, false);

        /// consume nonce. get back keyNonce.
        uint256 keyNonce =
            _useNonce(order.intent.withdraw.burner, uint192(order.intent.withdraw.accountId));

        DepositLibs.validateIntent(
            _hashTypedDataV4(order.intent.hashWithdrawIntent()),
            order.signature,
            order.intent.withdraw.burner,
            order.intent.chainId,
            keyNonce,
            order.intent.nonce
        );

        /// @notice The management fee should be charged before the withdrawal is processed
        /// otherwise, the management fee will be charged on the withdrawal amount
        _takeManagementFee();

        (uint256 assetAmountOut, uint256 netBrokerFee, uint256 netProtocolFee) =
            _withdraw(order.intent.withdraw.burner, order.intent.withdraw, broker.account);

        /// check that we can pay the bribe and relay tip with the net asset amount out
        if (assetAmountOut < order.intent.bribe + order.intent.relayerTip) {
            revert Errors.Deposit_InsufficientAmount();
        }

        /// deduct the bribe and relay tip from the net asset amount out
        assetAmountOut = assetAmountOut - order.intent.relayerTip - order.intent.bribe;

        /// distribute the funds to the user, broker, and protocol
        ERC20 assetToken = ERC20(order.intent.withdraw.asset);

        assetToken.pay(depositModule.fund(), order.intent.bribe);
        assetToken.pay(order.intent.withdraw.to, assetAmountOut);
        assetToken.pay(protocolFeeRecipient, netProtocolFee);
        assetToken.pay(broker.account.feeRecipient, netBrokerFee);
        assetToken.pay(msg.sender, order.intent.relayerTip);

        emit Withdraw(
            order.intent.withdraw.accountId,
            order.intent.withdraw.to,
            assetAmountOut,
            netProtocolFee,
            netBrokerFee
        );

        return assetAmountOut;
    }

    function withdraw(WithdrawOrder calldata order)
        public
        whenNotPaused
        nonReentrant
        checkOrderDeadline(order.deadline)
        zeroOutAccountInfo(order.accountId)
        returns (uint256)
    {
        (Broker storage broker, address burner) = _getBrokerOrRevert(order.accountId);

        if (!broker.account.isPublic && (burner != msg.sender && burner != order.burner)) {
            revert Errors.Deposit_OnlyAccountOwner();
        }

        _validateBrokerAssetPolicy(order.asset, broker, false);

        /// @notice The management fee should be charged before the withdrawal is processed
        /// otherwise, the management fee will be charged on the withdrawal amount
        _takeManagementFee();

        (uint256 assetAmountOut, uint256 netBrokerFee, uint256 netProtocolFee) =
            _withdraw(order.burner, order, broker.account);

        {
            /// distribute the funds to the user, broker, and protocol
            ERC20 assetToken = ERC20(order.asset);
            assetToken.pay(order.to, assetAmountOut);
            assetToken.pay(protocolFeeRecipient, netProtocolFee);
            assetToken.pay(broker.account.feeRecipient, netBrokerFee);
        }

        emit Withdraw(order.accountId, order.to, assetAmountOut, netProtocolFee, netBrokerFee);

        return assetAmountOut;
    }

    /// @notice Internal function to process a withdrawal and calculate fees
    /// @param burner The address burning shares to withdraw assets
    /// @param order The withdrawal order details
    /// @param account The broker account information
    /// @return assetAmountOut The amount of assets to send to the withdrawer
    /// @return netBrokerFee The amount of assets to send to the broker as fees
    /// @return netProtocolFee The amount of assets to send to the protocol as fees
    function _withdraw(
        address burner,
        WithdrawOrder calldata order,
        BrokerAccountInfo memory account
    ) private returns (uint256, uint256, uint256) {
        address shareToken = depositModule.getVault();
        uint256 sharesToBurn =
            order.shares == type(uint256).max ? ERC20(shareToken).balanceOf(burner) : order.shares;

        /// make sure the broker has not exceeded their share burn limit
        if (account.shareMintLimit != type(uint256).max) {
            if (account.totalSharesOutstanding < sharesToBurn) {
                revert Errors.Deposit_ShareBurnLimitExceeded();
            }

            /// update the broker's total shares outstanding
            brokers[order.accountId].account.totalSharesOutstanding -= sharesToBurn;
        }

        IPermit2(permit2).transferFrom(burner, address(this), uint160(sharesToBurn), shareToken);

        /// burn internalVault shares in exchange for liquidity (unit of account) tokens
        (uint256 netAssetAmountOut, uint256 liquidity) =
            depositModule.withdraw(order.asset, sharesToBurn, order.minAmountOut, address(this));

        /// take the withdrawal fees, and return the net liquidity left for the broker
        /// @notice this will consume part of the liquidity that was redeemed
        (uint256 netBrokerFeeInLiquidity, uint256 netProtocolFeeInLiquidity) =
            _calculateWithdrawalFees(account, sharesToBurn, liquidity);

        /// convert the fees to asset amount
        uint256 netBrokerFee =
            netBrokerFeeInLiquidity.divWadUp(liquidity).mulWadUp(netAssetAmountOut);
        uint256 netProtocolFee =
            netProtocolFeeInLiquidity.divWadUp(liquidity).mulWadUp(netAssetAmountOut);

        return (netAssetAmountOut - netBrokerFee - netProtocolFee, netBrokerFee, netProtocolFee);
    }

    function _getBrokerOrRevert(uint256 accountId_)
        private
        view
        returns (Broker storage broker, address brokerAddress)
    {
        brokerAddress = _ownerOf(accountId_);
        if (brokerAddress == address(0)) {
            revert Errors.Deposit_AccountDoesNotExist();
        }

        broker = brokers[accountId_];
    }

    function _validateBrokerAssetPolicy(address asset, Broker storage broker, bool isDeposit)
        internal
        view
    {
        BrokerAccountInfo memory account = broker.account;
        if (!account.isActive()) revert Errors.Deposit_AccountNotActive();

        if (account.isExpired() && isDeposit) {
            revert Errors.Deposit_AccountExpired();
        }

        if (!broker.assetPolicy[asset.brokerAssetPolicyPointer(isDeposit)]) {
            revert Errors.Deposit_AssetUnavailable();
        }
    }

    function _calculateWithdrawalFees(
        BrokerAccountInfo memory account,
        uint256 sharesBurnt,
        uint256 liquidityRedeemed
    ) private pure returns (uint256 netBrokerFee, uint256 netProtocolFee) {
        if (account.brokerPerformanceFeeInBps + account.protocolPerformanceFeeInBps > 0) {
            /// first we must calculate the performance in terms of unit of account
            /// peformance is the difference between the realized share price and the average share buy price
            /// if the realized share price is greater than the average share buy price, then the performance is positive
            /// if the realized share price is less than the average share buy price, then the performance is negative
            /// only take fee if the performance is positive
            /// @notice liquidity is priced in terms of unit of account
            /// @dev Invariant: 1 liquidity = 1 unit of account
            uint256 averageShareBuyPriceInUnitOfAccount =
                account.cumulativeUnitsDeposited.divWadUp(account.cumulativeSharesMinted);
            uint256 realizedSharePriceInUnitOfAccount = liquidityRedeemed.divWad(sharesBurnt);
            uint256 netPerformanceInTermsOfUnitOfAccount = realizedSharePriceInUnitOfAccount
                > averageShareBuyPriceInUnitOfAccount
                ? (realizedSharePriceInUnitOfAccount - averageShareBuyPriceInUnitOfAccount)
                    * sharesBurnt
                : 0;

            /// @notice netPerformance is scaled by WAD
            if (netPerformanceInTermsOfUnitOfAccount > 0) {
                if (account.protocolPerformanceFeeInBps > 0) {
                    netProtocolFee = netPerformanceInTermsOfUnitOfAccount.mulWadUp(
                        account.protocolPerformanceFeeInBps
                    ) / BP_DIVISOR;
                }
                if (account.brokerPerformanceFeeInBps > 0) {
                    netBrokerFee = netPerformanceInTermsOfUnitOfAccount.mulWadUp(
                        account.brokerPerformanceFeeInBps
                    ) / BP_DIVISOR;
                }
            }
        }

        /// Now take the exit fees. Exit fees are taken on the net withdrawal amount.
        if (account.protocolExitFeeInBps > 0) {
            netProtocolFee +=
                liquidityRedeemed.fullMulDivUp(account.protocolExitFeeInBps, BP_DIVISOR);
        }
        if (account.brokerExitFeeInBps > 0) {
            netBrokerFee += liquidityRedeemed.fullMulDivUp(account.brokerExitFeeInBps, BP_DIVISOR);
        }
    }

    function _takeManagementFee() private {
        uint256 timeDelta =
            managementFeeRateInBps > 0 ? block.timestamp - lastManagementFeeTimestamp : 0;
        if (timeDelta > 0) {
            /// update the last management fee timestamp
            lastManagementFeeTimestamp = block.timestamp;

            FundShareVault shareToken = depositModule.internalVault();
            uint256 totalSupply = shareToken.totalSupply();
            uint256 totalAssets = shareToken.totalAssets();

            /// if the internalVault has no assets, then we don't take any fees
            if (totalAssets == 0 || totalSupply == 0) {
                return;
            }

            /// calculate the annualized management fee rate
            uint256 annualizedFeeRate =
                managementFeeRateInBps.divWad(BP_DIVISOR) * timeDelta / 365 days;
            /// calculate the management fee in shares, remove WAD precision
            /// @notice mulWapUp rounds up in favor of the fee recipient, deter fuckery.
            uint256 managementFeeInShares = totalSupply.mulWadUp(annualizedFeeRate);

            /// mint the management fee to the fee recipient
            depositModule.dilute(managementFeeInShares, protocolFeeRecipient);

            emit ManagementFeeTaken(managementFeeInShares);
        }
    }

    /// @inheritdoc IPeriphery
    function grantApproval(address token_) external onlyRole(CONTROLLER_ROLE) {
        require(ERC20(token_).approve(address(depositModule), type(uint256).max));
    }

    /// @inheritdoc IPeriphery
    function revokeApproval(address token_) external onlyRole(CONTROLLER_ROLE) {
        require(ERC20(token_).approve(address(depositModule), 0));
    }

    /// @inheritdoc IPeriphery
    function setProtocolFeeRecipient(address recipient_)
        external
        whenNotPaused
        onlyRole(CONTROLLER_ROLE)
    {
        if (recipient_ == address(0)) {
            revert Errors.Deposit_InvalidProtocolFeeRecipient();
        }

        address previous = protocolFeeRecipient;

        /// update the fee recipient
        protocolFeeRecipient = recipient_;

        emit ProtocolFeeRecipientUpdated(recipient_, previous);
    }

    /// @inheritdoc IPeriphery
    function setBrokerFeeRecipient(uint256 accountId_, address recipient_) external whenNotPaused {
        address broker = _ownerOf(accountId_);
        if (broker == address(0)) {
            revert Errors.Deposit_AccountDoesNotExist();
        }
        if (broker != msg.sender) {
            revert Errors.Deposit_OnlyAccountOwner();
        }
        if (recipient_ == address(0)) {
            revert Errors.Deposit_InvalidBrokerFeeRecipient();
        }

        address previous = brokers[accountId_].account.feeRecipient;

        brokers[accountId_].account.feeRecipient = recipient_;

        emit BrokerFeeRecipientUpdated(accountId_, recipient_, previous);
    }

    /// @inheritdoc IPeriphery
    function setManagementFeeRateInBps(uint256 rateInBps_)
        external
        whenNotPaused
        onlyRole(CONTROLLER_ROLE)
    {
        if (rateInBps_ > BP_DIVISOR) {
            revert Errors.Deposit_InvalidManagementFeeRate();
        }

        uint256 previous = managementFeeRateInBps;

        managementFeeRateInBps = rateInBps_;

        emit ManagementFeeRateUpdated(previous, rateInBps_);
    }

    /// @inheritdoc IPeriphery
    function skimManagementFee() external {
        _takeManagementFee();
    }

    /// @inheritdoc IPeriphery
    function enableBrokerAssetPolicy(uint256 accountId_, address asset_, bool isDeposit_)
        external
        whenNotPaused
        onlyRole(ACCOUNT_MANAGER_ROLE)
    {
        Broker storage broker = brokers[accountId_];

        if (!broker.account.isActive()) {
            revert Errors.Deposit_AccountNotActive();
        }
        if (broker.account.isExpired()) {
            revert Errors.Deposit_AccountExpired();
        }

        broker.assetPolicy[asset_.brokerAssetPolicyPointer(isDeposit_)] = true;

        emit BrokerAssetPolicyEnabled(accountId_, asset_, isDeposit_);
    }

    /// @inheritdoc IPeriphery
    function disableBrokerAssetPolicy(uint256 accountId_, address asset_, bool isDeposit_)
        external
        onlyRole(ACCOUNT_MANAGER_ROLE)
    {
        Broker storage broker = brokers[accountId_];

        if (!broker.account.isActive()) {
            revert Errors.Deposit_AccountNotActive();
        }
        if (broker.account.isExpired()) {
            revert Errors.Deposit_AccountExpired();
        }

        broker.assetPolicy[asset_.brokerAssetPolicyPointer(isDeposit_)] = false;

        emit BrokerAssetPolicyDisabled(accountId_, asset_, isDeposit_);
    }

    /// @inheritdoc IPeriphery
    function isBrokerAssetPolicyEnabled(uint256 accountId_, address asset_, bool isDeposit_)
        external
        view
        returns (bool)
    {
        return brokers[accountId_].assetPolicy[asset_.brokerAssetPolicyPointer(isDeposit_)];
    }

    /// @notice restricting the transfer makes this a soulbound token
    function transferFrom(address from_, address to_, uint256 tokenId_)
        public
        override
        whenNotPaused
    {
        if (!brokers[tokenId_].account.transferable) revert Errors.Deposit_AccountNotTransferable();

        super.transferFrom(from_, to_, tokenId_);
    }

    /// @inheritdoc IPeriphery
    function openAccount(CreateAccountParams calldata params_)
        public
        whenNotPaused
        nonReentrant
        onlyRole(ACCOUNT_MANAGER_ROLE)
        returns (uint256 nextTokenId)
    {
        if (params_.user == address(0)) {
            revert Errors.Deposit_InvalidUser();
        }
        if (params_.brokerPerformanceFeeInBps + params_.protocolPerformanceFeeInBps >= BP_DIVISOR) {
            revert Errors.Deposit_InvalidPerformanceFee();
        }
        if (params_.brokerEntranceFeeInBps + params_.protocolEntranceFeeInBps >= BP_DIVISOR) {
            revert Errors.Deposit_InvalidEntranceFee();
        }
        if (params_.brokerExitFeeInBps + params_.protocolExitFeeInBps >= BP_DIVISOR) {
            revert Errors.Deposit_InvalidExitFee();
        }
        if (params_.ttl == 0) {
            revert Errors.Deposit_InvalidTTL();
        }
        if (params_.shareMintLimit == 0) {
            revert Errors.Deposit_InvalidShareMintLimit();
        }

        address feeRecipient =
            params_.feeRecipient == address(0) ? params_.user : params_.feeRecipient;

        unchecked {
            nextTokenId = ++tokenId;
        }

        /// @notice If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
        _safeMint(params_.user, nextTokenId);

        brokers[nextTokenId].account = BrokerAccountInfo({
            transferable: params_.transferable,
            isPublic: params_.isPublic,
            state: AccountState.ACTIVE,
            expirationTimestamp: block.timestamp + params_.ttl,
            feeRecipient: feeRecipient,
            shareMintLimit: params_.shareMintLimit,
            cumulativeSharesMinted: 0,
            cumulativeUnitsDeposited: 0,
            totalSharesOutstanding: 0,
            brokerPerformanceFeeInBps: params_.brokerPerformanceFeeInBps,
            protocolPerformanceFeeInBps: params_.protocolPerformanceFeeInBps,
            brokerEntranceFeeInBps: params_.brokerEntranceFeeInBps,
            protocolEntranceFeeInBps: params_.protocolEntranceFeeInBps,
            brokerExitFeeInBps: params_.brokerExitFeeInBps,
            protocolExitFeeInBps: params_.protocolExitFeeInBps
        });

        emit AccountOpened(
            nextTokenId,
            params_.user,
            block.timestamp + params_.ttl,
            params_.shareMintLimit,
            params_.transferable,
            params_.isPublic
        );
    }

    /// @inheritdoc IPeriphery
    function closeAccount(uint256 accountId_) public onlyRole(ACCOUNT_MANAGER_ROLE) {
        if (!brokers[accountId_].account.canBeClosed()) {
            revert Errors.Deposit_AccountCannotBeClosed();
        }
        /// @notice this will revert if the token does not exist
        _burn(accountId_);
        brokers[accountId_].account.state = AccountState.CLOSED;
    }

    /// @inheritdoc IPeriphery
    function pauseAccount(uint256 accountId_) public onlyRole(ACCOUNT_MANAGER_ROLE) {
        if (!brokers[accountId_].account.isActive()) {
            revert Errors.Deposit_AccountNotActive();
        }
        if (_ownerOf(accountId_) == address(0)) revert Errors.Deposit_AccountDoesNotExist();
        brokers[accountId_].account.state = AccountState.PAUSED;

        emit AccountPaused(accountId_);
    }

    /// @inheritdoc IPeriphery
    function unpauseAccount(uint256 accountId_)
        public
        whenNotPaused
        onlyRole(ACCOUNT_MANAGER_ROLE)
    {
        if (!brokers[accountId_].account.isPaused()) {
            revert Errors.Deposit_AccountNotPaused();
        }
        if (_ownerOf(accountId_) == address(0)) revert Errors.Deposit_AccountDoesNotExist();
        brokers[accountId_].account.state = AccountState.ACTIVE;

        emit AccountUnpaused(accountId_);
    }

    /// @inheritdoc IPeriphery
    function getAccountInfo(uint256 accountId_) public view returns (BrokerAccountInfo memory) {
        return brokers[accountId_].account;
    }

    /// @inheritdoc IPeriphery
    function increaseAccountNonce(uint256 accountId_) external {
        if (_ownerOf(accountId_) != msg.sender) revert Errors.Deposit_OnlyAccountOwner();
        if (brokers[accountId_].account.isActive()) {
            revert Errors.Deposit_AccountNotActive();
        }

        _useNonce(msg.sender, uint192(accountId_));
    }

    /// @inheritdoc IPeriphery
    function peekNextTokenId() public view returns (uint256) {
        return tokenId + 1;
    }

    /// @inheritdoc IPeriphery
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IPeriphery
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @inheritdoc IPeriphery
    function setPauser(address _pauser) external onlyRole(CONTROLLER_ROLE) {
        _grantRole(PAUSER_ROLE, _pauser);
    }

    /// @inheritdoc IPeriphery
    function revokePauser(address _pauser) external onlyRole(CONTROLLER_ROLE) {
        _revokeRole(PAUSER_ROLE, _pauser);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IPeriphery).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IPeriphery
    function domainSeparatorV4() public view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
