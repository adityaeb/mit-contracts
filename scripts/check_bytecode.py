#!/usr/bin/env python3
"""Prove that the code running on Robinhood Chain is the code in this repository.

For each contract: build it here with Foundry, read the code at its address from the chain's public RPC, and compare the two.
Values fixed at deployment (immutables, such as KolStake's token and amount) live inside the deployed code, so those bytes are
blanked on both sides before comparing; everything else must be identical, byte for byte.

    python3 scripts/check_bytecode.py            # needs `forge` and the test library (see README), nothing else
"""
import json
import os
import subprocess
import sys
import urllib.request

RPC = os.environ.get("RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACTS = [("locker", "TokenLocker", "0x4213382292ba3bdccddfdbc8e0fbc9ffc31974c6"),
             ("kolstake", "KolStake", "0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04")]


def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 headers={"content-type": "application/json", "user-agent": "mit-contracts-check"})
    out = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in out:
        raise SystemExit("RPC error: %s" % out["error"])
    return out["result"]


def main():
    if int(rpc("eth_chainId", []), 16) != 4663:
        raise SystemExit("This RPC is not Robinhood Chain (chain id 4663).")
    ok = True
    for folder, name, address in CONTRACTS:
        subprocess.run(["forge", "build", "--force", "--quiet"], cwd=os.path.join(ROOT, folder), check=True)
        art = json.load(open(os.path.join(ROOT, folder, "out", name + ".sol", name + ".json")))["deployedBytecode"]
        built, chain = list(art["object"][2:].lower()), list(rpc("eth_getCode", [address, "latest"])[2:].lower())
        same = len(built) == len(chain)
        if same:
            for refs in (art.get("immutableReferences") or {}).values():
                for r in refs:
                    for i in range(r["start"] * 2, (r["start"] + r["length"]) * 2):
                        built[i] = chain[i] = "0"
            same = built == chain
        ok = ok and same
        print("%-12s %s  %s  (%d bytes)" % (name, address, "MATCH" if same else "DIFFERENT", len(chain) // 2))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
