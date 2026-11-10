#!/usr/bin/env bash
# Rebuild KrexaSwapPolicy and KrexaRiskHook and check: build code hash == deployments/*.json == code on chain.
# Usage: ./script/verify-deployments.sh            (from evm/)
set -euo pipefail
cd "$(dirname "$0")/.."
forge build --force -q
rpc() { case "$1" in
  143) echo https://rpc.monad.xyz ;; 10143) echo https://testnet-rpc.monad.xyz ;;
  421614) echo https://sepolia-rollup.arbitrum.io/rpc ;; 42161) echo https://arb1.arbitrum.io/rpc ;;
  46630) echo https://rpc.testnet.chain.robinhood.com ;; 4663) echo https://rpc.mainnet.chain.robinhood.com ;;
  8453) echo https://mainnet.base.org ;; 84532) echo https://sepolia.base.org ;; *) echo "" ;; esac; }
fail=0
for f in deployments/*-evm-home.json; do
  id=$(jq -r .chainId "$f")
  for c in KrexaSwapPolicy KrexaRiskHook; do
    built=$(cast keccak "$(jq -r .deployedBytecode.object "out/$c.sol/$c.json")")
    want=$(jq -r ".${c}Codehash" "$f"); addr=$(jq -r ".$c" "$f")
    chain=$(cast keccak "$(cast code "$addr" --rpc-url "$(rpc "$id")")" 2>/dev/null || echo "rpc-error")  # keccak of the code: some RPCs (Monad) lack eth_getProof
    ok=OK; [[ "$built" == "$want" && "$want" == "$chain" ]] || { ok=MISMATCH; fail=1; }
    printf '%-7s %-16s %s %s\n' "$id" "$c" "$addr" "$ok"
  done
done
exit $fail
