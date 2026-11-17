// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title DemoToken
/// @notice Test-only token of the Notice Period demo (ours, not a real asset). 6 decimals, free mint.
contract DemoToken {
    string public constant name = "Notice Period Demo USD (test only)";
    string public constant symbol = "npUSD";
    uint8 public constant decimals = 6;
    /// @notice Largest amount one mint call can create: 1,000 tokens (1,000 * 10**6 base units).
    uint256 public constant MAX_MINT = 1_000 * 10 ** 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error MintTooLarge(uint256 amount, uint256 max);
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    function mint(address to_, uint256 amount_) external {
        if (amount_ > MAX_MINT) revert MintTooLarge(amount_, MAX_MINT);
        if (to_ == address(0)) revert ZeroAddress();
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount_) revert InsufficientAllowance();
            allowance[from_][msg.sender] = allowed - amount_;
        }
        _transfer(from_, to_, amount_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from_];
        if (bal < amount_) revert InsufficientBalance();
        unchecked {
            balanceOf[from_] = bal - amount_;
        }
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
