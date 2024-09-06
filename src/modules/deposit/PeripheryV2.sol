// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@solmate/tokens/ERC20.sol";
import "@openzeppelin-contracts/utils/math/Math.sol";
import "@openzeppelin-contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin-contracts/utils/math/SignedMath.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "@src/libs/Constants.sol";
import "@src/interfaces/IFund.sol";

import "@src/libs/Errors.sol";
import "@src/interfaces/IPeripheryV2.sol";
import "./UnitOfAccount.sol";
import {FundShareVault} from "./FundShareVault.sol";

contract PeripheryV2 is ERC721 {
    using SafeTransferLib for ERC20;
    using MessageHashUtils for bytes;
    using Math for uint256;
    using SignedMath for int256;

    /// @dev the DAMM fund the periphery is associated with
    IFund public immutable fund;
    /// @dev should be a Euler Oracle Router
    IPriceOracle public immutable oracleRouter;
    /// @dev common unit of account for assets and vault
    UnitOfAccount public immutable unitOfAccount;
    /// @dev used internally for yield accounting
    FundShareVault public immutable vault;

    /// @dev the minter role
    address immutable admin;

    uint256 public feeBps = 0;
    address public feeRecipient;
    uint256 public highWaterMarkPrice;
    uint256 public previousWaterMark;

    mapping(address asset => AssetPolicy policy) private assetPolicy;
    mapping(uint256 tokenId => UserAccountInfo account) private accountInfo;

    uint256 tokenId = 1;
    bool public paused;

    /// TODO: all of this in an intialize function
    constructor(
        string memory vaultName_,
        string memory vaultSymbol_,
        uint8 decimals_,
        address fund_,
        address oracleRouter_,
        address admin_,
        address feeRecipient_
    ) ERC721(string.concat(vaultName_, " Account"), string.concat("ACC-", vaultSymbol_)) {
        require(fund_ != address(0), "PeripheryV2: INVALID_FUND");
        require(oracleRouter_ != address(0), "PeripheryV2: INVALID_ORACLE_ROUTER");
        require(admin_ != address(0), "PeripheryV2: INVALID_ADMIN");
        require(feeRecipient_ != address(0), "PeripheryV2: INVALID_FEE_RECIPIENT");

        fund = IFund(fund_);
        oracleRouter = IPriceOracle(oracleRouter_);
        admin = admin_;
        feeRecipient = feeRecipient_;

        unitOfAccount = new UnitOfAccount("Liquidity", "UNIT", decimals_);
        vault = new FundShareVault(address(unitOfAccount), vaultName_, vaultSymbol_);

        /// @notice infinite approval for the vault to manage periphery's balance
        unitOfAccount.approve(address(vault), type(uint256).max);
    }

    modifier notPaused() {
        if (paused) revert Errors.Deposit_ModulePaused();
        _;
    }

    modifier onlyFund() {
        if (msg.sender != address(fund)) revert Errors.OnlyFund();
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "PeripheryV2: FORBIDDEN");
        _;
    }

    function _price(bool deposit) private view returns (uint256) {
        return deposit
            ? vault.previewMint(10 ** vault.decimals())
            : vault.previewRedeem(10 ** vault.decimals());
    }

    /// @dev A few things must happen here
    /// 1. Calculate the profit delta between the fund and the vault
    /// 2. Update the vault's total assets to match the fund's total assets
    /// 3. If there is profit above the high water mark, take a fee
    /// 4. Update the high water mark if the current price is higher
    /// 5. Invariants check
    modifier update(bool deposit) {
        uint256 assetsInFund = oracleRouter.getQuote(0, address(fund), address(unitOfAccount));
        uint256 assetsInVault = vault.totalAssets();

        int256 profitDelta = int256(assetsInFund) - int256(assetsInVault);

        if (profitDelta > 0) {
            unitOfAccount.mint(address(this), profitDelta.abs());

            /// we transfer the profit (deducting the fee) into the vault
            /// this will distribute the profit to the vault's shareholders
            if (!unitOfAccount.transfer(address(vault), profitDelta.abs())) {
                revert Errors.Deposit_AssetTransferFailed();
            }
        } else if (profitDelta < 0) {
            /// if the fund has lost value, we need to account for it
            /// so we decrease the vault's total assets to match the fund's total assets
            /// by burning the loss
            unitOfAccount.burn(address(vault), profitDelta.abs());
        }

        uint256 currentSharePrice = _price(deposit);

        /// if there is profit
        if (currentSharePrice > highWaterMarkPrice) {
            /// take a fee only on the profit above the high water mark price
            /// notice price has precision baked in so we must divide by it to get the actual profit
            uint256 nominalFee = feeBps > 0
                ? profitDelta.abs().mulDiv(
                    feeBps * (currentSharePrice - highWaterMarkPrice),
                    BP_DIVISOR * (currentSharePrice - previousWaterMark)
                )
                : 0;

            /// we will burn, mint, deposit as to not affect the vault's total assets
            /// and respect its underlying math calculations
            if (nominalFee > 0) {
                /// we burn the fee that was deposited into the vault
                unitOfAccount.burn(address(vault), nominalFee);

                /// we mint the fee to the periphery
                unitOfAccount.mint(address(this), nominalFee);

                /// we deposit the fee into the vault on behalf of the fee recipient
                vault.deposit(nominalFee, feeRecipient);
            }
        }

        /// update internal price
        previousWaterMark = currentSharePrice;
        if (previousWaterMark > highWaterMarkPrice) {
            highWaterMarkPrice = previousWaterMark;
        }

        _;

        /// invariants for 'some' peace of mind
        assetsInFund = oracleRouter.getQuote(0, address(fund), address(unitOfAccount));
        assetsInVault = vault.totalAssets();
        if (unitOfAccount.totalSupply() != assetsInVault) {
            revert Errors.Deposit_SupplyInvariantViolated();
        }
        if (assetsInFund != assetsInVault) {
            revert Errors.Deposit_AssetInvariantViolated();
        }
    }

    function deposit(SignedDepositIntent calldata order)
        public
        notPaused
        update(true)
        returns (uint256 sharesOut)
    {
        address minter = _ownerOf(order.intent.deposit.accountId);
        if (minter == address(0)) {
            revert Errors.Deposit_AccountNotAuthorized();
        }

        if (
            !SignatureChecker.isValidSignatureNow(
                minter, abi.encode(order.intent).toEthSignedMessageHash(), order.signature
            )
        ) revert Errors.Deposit_InvalidSignature();

        if (order.intent.chaindId != block.chainid) revert Errors.Deposit_InvalidChain();

        if (order.intent.nonce != accountInfo[order.intent.deposit.accountId].nonce++) {
            revert Errors.Deposit_InvalidNonce();
        }

        sharesOut = _deposit(order.intent.deposit, minter);

        /// pay the relayer if required
        if (order.intent.relayerTip > 0) {
            ERC20(order.intent.deposit.asset).safeTransferFrom(
                minter, msg.sender, order.intent.relayerTip
            );
        }

        // emit Deposit(
        //     order.intent.user,
        //     order.intent.order.asset,
        //     assetAmountIn,
        //     sharesOut,
        //     msg.sender,
        //     order.intent.relayerTip
        // );
    }

    function _deposit(DepositOrder calldata order, address user)
        private
        returns (uint256 sharesOut)
    {
        AssetPolicy memory policy = assetPolicy[order.asset];

        if (order.deadline < block.timestamp) {
            revert Errors.Deposit_OrderExpired();
        }

        UserAccountInfo memory account = accountInfo[order.accountId];

        // if(account.state != AccountState.ACTIVE) revert Errors.Deposit_AccountNotActive();

        if (account.expirationTimestamp != 0 && block.timestamp >= account.expirationTimestamp) {
            revert Errors.Deposit_AccountExpired();
        }

        if (!policy.canDeposit || !policy.enabled) {
            revert Errors.Deposit_AssetUnavailable();
        }

        if (policy.permissioned && account.role != Role.SUPER_USER) {
            revert Errors.Deposit_OnlySuperUser();
        }

        uint256 assetAmountIn = order.amount;
        ERC20 assetToken = ERC20(order.asset);

        /// if amount is 0, then deposit the user's entire balance
        if (assetAmountIn == 0) {
            assetAmountIn = assetToken.balanceOf(user);
        }

        /// transfer asset from user to fund
        assetToken.safeTransferFrom(user, address(fund), assetAmountIn);

        /// calculate how much liquidity for this amount of deposited asset
        uint256 liquidity =
            oracleRouter.getQuote(assetAmountIn, order.asset, address(unitOfAccount));

        /// make sure the deposit is above the minimum
        if (liquidity < policy.minimumDeposit) {
            revert Errors.Deposit_InsufficientDeposit();
        }

        /// mint liquidity to periphery
        unitOfAccount.mint(address(this), liquidity);

        /// mint shares to user using the liquidity that was just minted to periphery
        sharesOut = vault.deposit(liquidity, order.recipient);

        /// lets make sure slippage is acceptable
        if (sharesOut < order.minSharesOut) {
            revert Errors.Deposit_SlippageLimitExceeded();
        }
    }

    function withdraw(SignedWithdrawIntent calldata order)
        public
        notPaused
        update(false)
        returns (uint256 assetAmountOut)
    {
        address burner = _ownerOf(order.intent.withdraw.accountId);
        require(burner != address(0), "PeripheryV2: INVALID_ACCOUNT");
        if (
            !SignatureChecker.isValidSignatureNow(
                burner, abi.encode(order.intent).toEthSignedMessageHash(), order.signature
            )
        ) revert Errors.Deposit_InvalidSignature();

        if (order.intent.nonce != accountInfo[order.intent.withdraw.accountId].nonce++) {
            revert Errors.Deposit_InvalidNonce();
        }

        if (order.intent.chaindId != block.chainid) revert Errors.Deposit_InvalidChain();

        /// withdraw liquidity from vault
        assetAmountOut = _withdraw(order.intent.withdraw, burner);

        /// pay the relayer if required
        if (order.intent.relayerTip > 0) {
            if (order.intent.relayerTip >= assetAmountOut) {
                revert Errors.Deposit_InsufficientAmount();
            }

            _transferAssetFromFund(order.intent.withdraw.asset, msg.sender, order.intent.relayerTip);
        }

        /// transfer asset from fund to receiver
        _transferAssetFromFund(
            order.intent.withdraw.asset,
            order.intent.withdraw.to,
            assetAmountOut - order.intent.relayerTip
        );

        // emit Withdraw(
        //     order.intent.user,
        //     order.intent.to,
        //     order.intent.asset,
        //     order.intent.shares,
        //     assetAmountOut,
        //     msg.sender,
        //     order.intent.relayerTip
        // );
    }

    function _withdraw(WithdrawOrder calldata order, address user)
        private
        returns (uint256 assetAmountOut)
    {
        if (order.deadline < block.timestamp) revert Errors.Deposit_OrderExpired();

        AssetPolicy memory policy = assetPolicy[order.asset];

        if (!policy.canWithdraw || !policy.enabled) {
            revert Errors.Deposit_AssetUnavailable();
        }

        if (policy.permissioned && accountInfo[order.accountId].role != Role.SUPER_USER) {
            revert Errors.Deposit_OnlySuperUser();
        }

        uint256 sharesToBurn = order.shares;

        /// if shares to burn is 0, then burn all shares owned by user
        if (sharesToBurn == 0) {
            sharesToBurn = vault.balanceOf(user);
        }

        /// burn vault shares in exchange for liquidity (unit of account) tokens
        uint256 liquidity = vault.redeem(sharesToBurn, address(this), user);

        /// make sure the withdrawal is above the minimum
        if (liquidity < policy.minimumWithdrawal) {
            revert Errors.Deposit_InsufficientWithdrawal();
        }

        /// burn liquidity from periphery
        unitOfAccount.burn(address(this), liquidity);

        /// calculate how much asset for this amount of liquidity
        assetAmountOut = oracleRouter.getQuote(liquidity, address(unitOfAccount), order.asset);

        /// make sure slippage is acceptable
        ///@notice if minAmountOut is 0, then slippage is not checked
        if (order.minAmountOut > 0 && assetAmountOut < order.minAmountOut) {
            revert Errors.Deposit_SlippageLimitExceeded();
        }
    }

    function _transferAssetFromFund(address asset, address to, uint256 amount) private {
        /// call fund to transfer asset out
        (bool success, bytes memory returnData) = fund.execTransactionFromModuleReturnData(
            asset,
            0,
            abi.encodeWithSignature("transfer(address,uint256)", to, amount),
            Enum.Operation.Call
        );

        /// check transfer was successful
        if (!success || (returnData.length > 0 && !abi.decode(returnData, (bool)))) {
            revert Errors.Deposit_AssetTransferFailed();
        }
    }

    function getAccountNonce(uint256 accountId_) external view returns (uint256) {
        return accountInfo[accountId_].nonce;
    }

    function setFeeBps(uint256 bps) external notPaused onlyFund {
        if (bps >= BP_DIVISOR) {
            revert Errors.Deposit_InvalidPerformanceFee();
        }
        uint256 oldFee = feeBps;
        feeBps = bps;

        // emit PerformanceFeeUpdated(oldFee, bps);
    }

    function enableAsset(address asset_, AssetPolicy memory policy_) external notPaused onlyFund {
        if (!fund.isAssetOfInterest(asset_)) {
            revert Errors.Deposit_AssetNotSupported();
        }
        if (!policy_.enabled) {
            revert Errors.Deposit_InvalidAssetPolicy();
        }

        assetPolicy[asset_] = policy_;

        // emit AssetEnabled(asset, policy);
    }

    function disableAsset(address asset_) external notPaused onlyFund {
        assetPolicy[asset_].enabled = false;

        // emit AssetDisabled(asset);
    }

    function getAssetPolicy(address asset_) external view returns (AssetPolicy memory) {
        return assetPolicy[asset_];
    }

    /// @notice restricting the transfer makes this a soulbound token
    function transferFrom(address from_, address to_, uint256 tokenId_) public override onlyFund {
        super.transferFrom(from_, to_, tokenId_);
    }

    function openAccount(address user_, uint256 expirationTimestamp_, Role role_)
        public
        notPaused
        onlyAdmin
    {
        _safeMint(user_, tokenId++);
        accountInfo[tokenId] = UserAccountInfo(role_, AccountState.ACTIVE, expirationTimestamp_, 0);
    }

    function closeAccount(uint256 accountId_) public onlyAdmin {
        _burn(accountId_);
        accountInfo[accountId_].state = AccountState.CLOSED;
    }

    function pauseAccount(uint256 accountId_) public onlyAdmin {
        require(accountInfo[accountId_].state == AccountState.ACTIVE, "PeripheryV2: INVALID_STATUS");
        accountInfo[accountId_].state = AccountState.PAUSED;
    }

    function unpauseAccount(uint256 accountId_) public notPaused onlyAdmin {
        require(accountInfo[accountId_].state == AccountState.PAUSED, "PeripheryV2: INVALID_STATUS");
        accountInfo[accountId_].state = AccountState.ACTIVE;

        /// increase nonce to avoid replay attacks
        accountInfo[accountId_].nonce++;
    }

    /// TODO: add min/max mint/burn amount per account
    function getAccountInfo(uint256 accountId_) public view returns (UserAccountInfo memory) {
        return accountInfo[accountId_];
    }

    function pause() external onlyFund {
        paused = true;

        // emit Paused();
    }

    function unpause() external onlyFund {
        paused = false;

        // emit Unpaused();
    }
}
