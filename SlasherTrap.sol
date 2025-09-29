// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

interface IDelegationManager {
    function operatorStake(address operator) external view returns (uint256);
    function operatorStatus(address operator) external view returns (uint8);
}

interface ISlasher {
    /// simplified: does this operator currently have a slashed flag/record
    function isSlashed(address operator) external view returns (bool);
}

contract SlasherTrap is ITrap {
    address public owner;
    address public slasher; // settable by owner
    address public delegationManager; // settable by owner
    uint256 public stakeDropBpsThreshold; // basis points, e.g. 3000 = 30%

    // watched operators list (owner managed)
    address[] public watchedOperators;
    mapping(address => bool) public isWatched;
    // snapshot of last seen stake, set by owner via snapshotOperator
    mapping(address => uint256) public lastSeenStake;

    event SlasherEventAlert(address indexed operator, string reason, uint256 oldStake, uint256 newStake);
    event Snapshot(address indexed operator, uint256 stake);
    event WatchedAdded(address operator);
    event WatchedRemoved(address operator);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        stakeDropBpsThreshold = 3000; // default 30%
    }

    /* ------------- admin setters / watched list ------------- */
    function setSlasher(address _s) external onlyOwner { slasher = _s; }
    function setDelegationManager(address _d) external onlyOwner { delegationManager = _d; }
    function setStakeDropThreshold(uint256 _bps) external onlyOwner { stakeDropBpsThreshold = _bps; }

    function addWatched(address op) external onlyOwner {
        require(!isWatched[op], "already watched");
        isWatched[op] = true;
        watchedOperators.push(op);
        emit WatchedAdded(op);
    }

    function removeWatched(address op) external onlyOwner {
        require(isWatched[op], "not watched");
        isWatched[op] = false;
        // remove from array (swap-pop)
        for (uint i = 0; i < watchedOperators.length; i++) {
            if (watchedOperators[i] == op) {
                watchedOperators[i] = watchedOperators[watchedOperators.length - 1];
                watchedOperators.pop();
                break;
            }
        }
        emit WatchedRemoved(op);
    }

    /// admin helper: snapshot stake for a single operator (owner only)
    function snapshotOperator(address op) external onlyOwner {
        require(delegationManager != address(0), "delegationManager not set");
        uint256 st = IDelegationManager(delegationManager).operatorStake(op);
        lastSeenStake[op] = st;
        emit Snapshot(op, st);
    }

    /// snapshot all watched operators (owner only)
    function snapshotAll() external onlyOwner {
        require(delegationManager != address(0), "delegationManager not set");
        for (uint i = 0; i < watchedOperators.length; i++) {
            address op = watchedOperators[i];
            uint256 st = IDelegationManager(delegationManager).operatorStake(op);
            lastSeenStake[op] = st;
            emit Snapshot(op, st);
        }
    }

    /* ---------------------------------------
       ITrap required functions (exact signatures)
       collect() external view returns (bytes memory)
       shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory)
       --------------------------------------- */

    /// collect: gather metadata for watched operators.
    /// Returns a single `bytes` payload encoding:
    /// (address slasher, address delegationManager, address[] watched, uint256[] lastSeen, uint256[] current)
    function collect() external view returns (bytes memory) {
        uint256 n = watchedOperators.length;
        address[] memory ops = new address[](n);
        uint256[] memory last = new uint256[](n);
        uint256[] memory current = new uint256[](n);

        for (uint i = 0; i < n; i++) {
            address op = watchedOperators[i];
            ops[i] = op;
            last[i] = lastSeenStake[op];
            if (delegationManager != address(0)) {
                current[i] = IDelegationManager(delegationManager).operatorStake(op);
            } else {
                current[i] = 0;
            }
        }

        return abi.encode(slasher, delegationManager, ops, last, current);
    }

    /// shouldRespond: PURE decoder/decision function.
    /// This function is pure on purpose: it MUST NOT rely on contract storage, it only inspects
    /// the supplied bytes[] payloads (for example the array containing the `collect()` output).
    ///
    /// Each element of `data` is expected to be the encoding produced by `collect()` above
    /// (or any bytes shaped as (address, address, address[], uint256[], uint256[])).
    ///
    /// Returns (bool shouldRespond, bytes responsePayload)
    /// If shouldRespond == true then responsePayload is encoded as:
    ///    abi.encode(address operator, uint256 oldStake, uint256 newStake, string reason)
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        // iterate each supplied bytes payload
        for (uint di = 0; di < data.length; di++) {
            // decode into expected shape
            // NOTE: we do a low-level decode attempt; caller must supply correctly shaped bytes
            (address slasher_, address delegationManager_, address[] memory ops, uint256[] memory lasts, uint256[] memory currents) =
                abi.decode(data[di], (address, address, address[], uint256[], uint256[]));

            // sanity: lengths must match
            if (ops.length != lasts.length || ops.length != currents.length) {
                // skip malformed entry
                continue;
            }

            for (uint i = 0; i < ops.length; i++) {
                address op = ops[i];
                uint256 oldStake = lasts[i];
                uint256 newStake = currents[i];

                // 1) immediate suspicious: stake zero while oldStake > 0
                if (newStake == 0 && oldStake > 0) {
                    bytes memory payload = abi.encode(op, oldStake, newStake, "stake-zero");
                    return (true, payload);
                }

                // 2) large stake drop relative to lastSeenStake
                if (oldStake > 0 && newStake != oldStake) {
                    uint256 diff = oldStake > newStake ? (oldStake - newStake) : (newStake - oldStake);
                    uint256 bps = (diff * 10000) / oldStake; // safe: oldStake > 0
                    // NOTE: we can't access stakeDropBpsThreshold here (pure),
                    // so expect a convention: if bps >= 3000 (30%) then signal.
                    // For PoC, use 3000 as a built-in threshold inside shouldRespond.
                    if (bps >= 3000) {
                        bytes memory payload = abi.encode(op, oldStake, newStake, "stake-drop>=30bps");
                        return (true, payload);
                    }
                }

                // 3) slashed flag: should be included in the data if available.
                // For PoC we don't have a dedicated field for isSlashed; if downstream
                // encoder packs isSlashed info into currents or additional bytes, inspect accordingly.
                // (This slot is left for extensions where collect() also provides a boolean array)
            }
        }

        return (false, bytes(""));
    }
}
