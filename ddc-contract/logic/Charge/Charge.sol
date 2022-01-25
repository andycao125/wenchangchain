// SPDX-License-Identifier: BSN DDC

pragma solidity ^0.8.0;

import "../../interface/Charge/ICharge.sol";
import "../../interface/Authority/IAuthority.sol";
import "../../utils/OwnableUpgradeable.sol";
import "../../utils/AddressUpgradeable.sol";
import "../../utils/StringsUpgradeable.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";

/// @title DDC charge contract
/// @author Gao Chanxi
/// @notice DDC charge contract
/// @dev
contract Charge is ICharge, OwnableUpgradeable, UUPSUpgradeable {
    using AddressUpgradeable for address;
    using StringsUpgradeable for string;

    uint256 private _total;

    // Mapping from ddc address to function fee
    mapping(address => FuncFee) private _ddcFees;

    struct FuncFee {
        mapping(bytes4 => uint32) funcFee;
        bool used;
    }

    // Mapping from ddc address to account balances
    mapping(address => uint256) private _balances;

    IAuthority private _authorityProxy;

    constructor() initializer {}

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     *
     * Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /**
     * @dev See {ICharge-setAuthorityProxyAddress}.
     */
    function setAuthorityProxyAddress(address authorityProxyAddress)
        external
        override
        onlyOwner
    {
        require(
            address(0) != authorityProxyAddress,
            "charge: auth the zero address"
        );
        _authorityProxy = IAuthority(authorityProxyAddress);
    }

    /**
     * @dev See {ICharge-recharge}.
     */
    function recharge(address to, uint256 amount) external override {
        require(amount != 0, "charge: no transfer is necessary");
        _checkRechargeAuth(_msgSender(), to);
        _recharge(_msgSender(), to, amount);
        emit Recharge(_msgSender(), to, amount);
    }

    /**
     * @dev See {ICharge-selfRecharge}.
     */
    function selfRecharge(uint256 amount) external override {
        require(amount != 0, "charge: no transfer is necessary");
        _requireOperator();
        _recharge(address(0), _msgSender(), amount);
        emit Recharge(address(0), _msgSender(), amount);
    }

    /**
     * @dev See {ICharge-pay}.
     */
    function pay(
        address payer,
        bytes4 sig,
        uint256 ddcId
    ) external override {
        require(payer != address(0), "charge:zero address");
        require(ddcId != 0, "charge:invalid ddcId");
        address payee = _msgSender();
        //query fee by call DCC function.
        uint32 amount = Charge.queryFee(payee, sig);
        if (amount > 0) {
            _recharge(payer, payee, amount);
        }
        emit Pay(payer, payee, sig, amount, ddcId);
    }

    /**
     * @dev See {ICharge-settlement}.
     */
    function settlement(address ddcAddr, uint256 amount) external override {
        require(amount != 0, "charge: no transfer is necessary");
        require(
            ddcAddr.isContract() && _ddcFees[ddcAddr].used,
            "charge: not DDC contract"
        );
        _requireOperator();
        _recharge(ddcAddr, _msgSender(), amount);
        emit Settlement(_msgSender(), ddcAddr, amount);
    }

    /**
     * @dev See {ICharge-setFee}.
     */
    function setFee(
        address ddcAddr,
        bytes4 sig,
        uint32 amount
    ) external override {
        require(ddcAddr != address(0), "charge:zero address");
        _requireOperator();
        _ddcFees[ddcAddr].used = true;
        (_ddcFees[ddcAddr].funcFee)[sig] = amount;
        emit SetFee(ddcAddr, sig, amount);
    }

    /**
     * @dev See {ICharge-deleteFee}.
     */
    function delFee(address ddcAddr, bytes4 sig) external override {
        require(ddcAddr != address(0), "charge:zero address");
        _requireOperator();
        delete (_ddcFees[ddcAddr].funcFee)[sig];
        emit DelFee(ddcAddr, sig);
    }

    /**
     * @dev See {ICharge-deleteDDC}.
     */
    function delDDC(address ddcAddr) external override {
        require(ddcAddr != address(0), "charge:zero address");
        _requireOperator();
        _ddcFees[ddcAddr].used = false;
        emit DelDDC(ddcAddr);
    }

    /**
     * @dev See {ICharge-balanceOf}.
     */
    function balanceOf(address accAddr) public view override returns (uint256) {
        require(address(0) != accAddr, "charge:zero address");
        return _balances[accAddr];
    }

    /**
     * @dev See {ICharge-queryFee}.
     */
    function queryFee(address ddcAddr, bytes4 sig)
        public
        view
        override
        returns (uint32)
    {
        require(address(0) != ddcAddr, "charge:zero address");
        require(
            _ddcFees[ddcAddr].used,
            "charge:ddc proxy contract unavailable"
        );
        return (_ddcFees[ddcAddr].funcFee)[sig];
    }

    /**
     * @dev See {ICharge-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _total;
    }

    /**
     * @dev Requires sender's role must be `Role.Operator`.
     */
    function _requireOperator() private view {
        require(
            _authorityProxy.checkAvailableAndRole(
                _msgSender(),
                IAuthority.Role.Operator
            ),
            "DDC721:not a operator role or disabled"
        );
    }

    /**
     * @dev Transfer amount to `to` from `from`.
     */
    function _recharge(
        address from,
        address to,
        uint256 amount
    ) private {
        if (from != address(0)) {
            require(
                Charge.balanceOf(from) >= amount,
                "charge: account balance is not enough"
            );
            _balances[from] -= amount;
        } else {
            _total += amount;
        }
        _balances[to] += amount;
    }

    /**
     * @dev Check persmissions of Recharge
     */
    function _checkRechargePermission(address from, address to)
        private
        view
        returns (bool)
    {
        IAuthority.AccountInfo memory fromAcc;
        (
            fromAcc.accountDID,
            ,
            fromAcc.accountRole,
            fromAcc.leaderDID,
            fromAcc.platformState,
            fromAcc.operatorState,

        ) = _authorityProxy.getAccount(from);

        // check from state
        require(
            (fromAcc.platformState == IAuthority.State.Active &&
                fromAcc.operatorState == IAuthority.State.Active),
            "charge: account is frozen"
        );

        IAuthority.AccountInfo memory toAcc; //= _authorityProxy.getAccount(to);
        (
            toAcc.accountDID,
            ,
            toAcc.accountRole,
            toAcc.leaderDID,
            toAcc.platformState,
            toAcc.operatorState,

        ) = _authorityProxy.getAccount(to);
        // check to state
        require(
            (toAcc.platformState == IAuthority.State.Active &&
                toAcc.operatorState == IAuthority.State.Active),
            "charge: to is frozen"
        );

        require(
            fromAcc.accountRole != IAuthority.Role.Consumer,
            "charge: no recharge permission"
        );

        //fromAcc.leaderDID.equal(toAcc.accountDID) ||
        // fromAcc.accountDID.equal(toAcc.leaderDID) ||
        // (fromAcc.leaderDID.equal(toAcc.leaderDID) &&
        //     fromAcc.accountDID.equal(toAcc.accountDID) &&
        //     toAcc.accountRole != IAuthorityLogic.Role.Consumer);

        return
            fromAcc.accountRole == IAuthority.Role.Operator ||
            fromAcc.accountDID.equal(toAcc.leaderDID) ||
            (fromAcc.leaderDID.equal(toAcc.leaderDID) &&
                fromAcc.accountDID.equal(toAcc.accountDID) &&
                toAcc.accountRole != IAuthority.Role.Consumer);
    }

    /**
     * @dev Check conditions of Recharge
     */
    function _checkRechargeAuth(address from, address to) private view {
        require(to != address(0), "charge: recharge to the zero address");
        require(from != to, "charge: no recharge is necessary");
        require(
            _checkRechargePermission(from, to),
            "charge: no recharge permission"
        );
    }
}
