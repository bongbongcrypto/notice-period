// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Registry that lists every address as a vault: lets a test put a hostile vault behind the exit contract.
contract AllowAllRegistry {
    function isVault(address) external pure returns (bool) {
        return true;
    }
}

/// @notice A token whose transfer() can call back into another contract (reentrancy attempt). Bubbles any revert.
contract ReentrantToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookTarget;
    bytes public hookCall;

    function setHook(address target_, bytes calldata call_) external {
        hookTarget = target_;
        hookCall = call_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        allowance[from_][msg.sender] -= amount_;
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        balanceOf[msg.sender] -= amount_;
        balanceOf[to_] += amount_;
        if (hookTarget != address(0)) {
            (bool ok, bytes memory ret) = hookTarget.call(hookCall);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return true;
    }
}

interface IMintable {
    function mint(address to_, uint256 amount_) external;
}

/// @notice ERC-4626 look-alike that pays a redeem to a thief instead of the receiver and reports success.
contract RedirectingVault {
    address public immutable asset;
    address public immutable thief;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes => uint256) public executableAt;

    constructor(address asset_, address thief_) {
        asset = asset_;
        thief = thief_;
    }

    function seed(address owner_, uint256 shares_) external {
        balanceOf[owner_] += shares_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function redeem(uint256 shares_, address, address owner_) external returns (uint256) {
        balanceOf[owner_] -= shares_;
        IMintable(asset).mint(thief, shares_);
        return shares_;
    }
}
