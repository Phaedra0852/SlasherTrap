# SlasherTrap — Slashing / Double-Sign Risk Detector (PoC)

## Overview
**SlasherTrap** is a Drosera-compatible trap that monitors EigenLayer operator risk on the Hoodi testnet.  
It detects:
- operators with `isSlashed` flags,
- sudden stake drops (configurable basis point threshold),
- operators with zeroed stake since the last snapshot.

When a trap condition is met, the Drosera relay can call a responder function on a deployed responder contract (`SlasherResponder`) which emits an event and can be integrated with governance or alerting flows.

## Architecture
- `SlasherTrap.sol` — main trap (implements Drosera `ITrap` interface; `collect(bytes)` and `shouldRespond(bytes)` required)
- `SlasherResponder.sol` — response contract to be deployed on Remix (simple event emitter for PoC)
- `drosera.toml` — configuration for the Drosera relay (samples included)

## Hoodi addresses
- DelegationManager (Hoodi proxy): `0x867837a9722C512e0862d8c2E15b8bE220E8b87d`. (From eigenlayer-contracts repo)
- AVSDirectory (Hoodi proxy): `0xD58f6844f79eB1fbd9f7091d05f7cb30d3363926`. (From eigenlayer-contracts repo)

> The Slasher/Slashing contract address is not present as a single `Slasher` entry in the top-level table of the repo README; if you have a definitive slasher address, set it using `setSlasher(...)` after deployment. See the testing section below for commands.

## Quick test / cast commands
1. `cast send <TRAP> "setDelegationManager(address)" 0x8678... --private-key $PK --rpc-url https://ethereum-hoodi-rpc.publicnode.com`
2. `cast send <TRAP> "snapshotOperator(address)" 0xOP --private-key $PK --rpc-url https://ethereum-hoodi-rpc.publicnode.com`
3. `DATA=$(cast abi-encode "address[]" 0xOP)`  
   `cast call <TRAP> "shouldRespond(bytes)" $DATA --rpc-url https://ethereum-hoodi-rpc.publicnode.com`
4. `OPDATA=$(cast abi-encode "address" 0xOP)`  
   `cast call <TRAP> "collect(bytes)" $OPDATA --rpc-url https://ethereum-hoodi-rpc.publicnode.com`
5. Relay / operator calls responder:  
   `cast send <RESP> "respondWithSlashingAlert(address,uint256,uint256,string)" 0xOP 1000000000000000000 500000000000000000 "stake-dropped-50pct" --private-key $PK --rpc-url https://ethereum-hoodi-rpc.publicnode.com`



