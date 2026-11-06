#!/usr/bin/env python3
"""Queue 100 crossing Router transactions per workload on disposable loopback Anvil."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BLOCK_GAS = 30_000_000
SIZE = 10**18
BID = 100_000
TOKEN0, TOKEN1 = (
    "0x0000000000000000000000000000000000100000",
    "0x0000000000000000000000000000000000200000",
)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument(
    "--reuse-export",
    action="store_true",
    help="Debug only: reuse the local fixture export",
)
p.add_argument("--workload", help="Run one named workload instead of all ten")
p.add_argument(
    "--output-dir",
    default="benchmarks/crossing/batched-results",
    help="Separate result directory for prototype comparisons",
)
a = p.parse_args()
OUT = ROOT / a.output_dir
OUT.mkdir(parents=True, exist_ok=True)
(ROOT / "deployments").mkdir(parents=True, exist_ok=True)
log = ROOT / ".local/crossing/export.log"
log.parent.mkdir(parents=True, exist_ok=True)
if not a.reuse_export:
    env = dict(
        os.environ,
        FOUNDRY_PROFILE="current",
        FOUNDRY_TEST="benchmarks/crossing/fixtures",
        FOUNDRY_OUT=".local/crossing/out",
        FOUNDRY_CACHE_PATH=".local/crossing/cache",
    )
    with log.open("w") as output:
        subprocess.run(
            [
                "forge",
                "test",
                "--match-contract",
                "CrossingCapacityTest",
                "--match-test",
                "test_export",
                "--no-dynamic-test-linking",
                "--gas-limit",
                "10000000000",
                "-vv",
            ],
            cwd=ROOT,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            check=True,
        )
export = log.read_text()
metas = re.findall(
    r"META\|([^|\s]+)\|([^|\s]+)\|([^|\s]+)\|([^|\s]+)\|([^|\s]+)\|(0x[0-9a-fA-F]+)",
    export,
)
assert len(metas) == 10


def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], text=True).strip()


MATCH = cast("keccak", "AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)")
CREATE = cast(
    "keccak", "AsyncOrderCreated(bytes32,bytes32,address,bool,uint256,uint256,bytes32)"
)
SELECTORS = {
    s: cast("sig", s)
    for s in [
        "asyncOrder(bytes32,bytes32)",
        "balanceOf(address,uint256)",
        "bestOrder(bytes32,bool)",
    ]
}


def word(x):
    return (x[2:] if isinstance(x, str) else hex(x)[2:]).zfill(64)


def calldata(sig, *args):
    return SELECTORS[sig] + "".join(word(x) for x in args)


def measure(meta):
    name, router, hook, manager, vault, pool = meta
    depth = 8 if "_eight_" in name else 1
    resting_sell = name.startswith("buy_")
    makers = re.findall(
        r"MAKER\|" + name + r"\|(0x[0-9a-fA-F]+)\|(0x[0-9a-fA-F]+)\|(\d+)", export
    )
    commands = re.findall(
        r"TX\|" + name + r"\|(0x[0-9a-fA-F]+)\|(0x[0-9a-fA-F]+)", export
    )
    assert len(makers) == 100 * depth and len(commands) == 100
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    process = subprocess.Popen(
        [
            "anvil",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--chain-id",
            "31337",
            "--gas-limit",
            str(BLOCK_GAS),
            "--hardfork",
            "cancun",
            "--base-fee",
            "0",
            "--timestamp",
            "1",
            "--order",
            "fifo",
            "--silent",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )

    def batch(items):
        payload = [
            {"jsonrpc": "2.0", "id": i, "method": m, "params": params}
            for i, (m, params) in enumerate(items)
        ]
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        response = json.load(urllib.request.urlopen(request, timeout=120))
        ordered = sorted(response, key=lambda x: x["id"])
        assert len(ordered) == len(items) and all("error" not in x for x in ordered), (
            ordered
        )
        return [x["result"] for x in ordered]

    def rpc(method, params=None):
        return batch([(method, params or [])])[0]

    def call(to, data):
        return ("eth_call", [{"to": to, "data": data}, "latest"])

    try:
        for _ in range(100):
            assert process.poll() is None, process.stderr.read().decode()
            try:
                assert rpc("eth_chainId") == "0x7a69"
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Anvil startup timed out")
        assert "anvil" in rpc("web3_clientVersion").lower()
        fixture = ROOT / f"deployments/crossing-{name}.json"
        state = json.loads(fixture.read_text())
        updates = []
        for address, account in state.items():
            if account["code"] != "0x":
                updates.append(("anvil_setCode", [address, account["code"]]))
            if int(account["balance"], 16):
                updates.append(("anvil_setBalance", [address, account["balance"]]))
            if int(account["nonce"], 16):
                updates.append(("anvil_setNonce", [address, account["nonce"]]))
            updates.extend(
                ("anvil_setStorageAt", [address, slot, value])
                for slot, value in account["storage"].items()
                if int(value, 16)
            )
        for start in range(0, len(updates), 200):
            batch(updates[start : start + 200])
        for actor, _ in commands:
            batch(
                [
                    ("anvil_impersonateAccount", [actor]),
                    ("anvil_setBalance", [actor, hex(10**20)]),
                    ("anvil_setNonce", [actor, "0x0"]),
                ]
            )
        estimate = int(
            rpc(
                "eth_estimateGas",
                [
                    {
                        "from": commands[0][0],
                        "to": router,
                        "data": commands[0][1],
                        "gasPrice": "0x0",
                    }
                ],
            ),
            16,
        )
        # Real block admission reserves each transaction's gas limit. Record a reproducible 20% margin.
        gas_limit = ((estimate * 120 + 99) // 100 + 999) // 1000 * 1000
        assert gas_limit < BLOCK_GAS
        rpc("evm_setAutomine", [False])
        rpc("evm_setNextBlockTimestamp", [1000])
        hashes = []
        for actor, data in commands:
            hashes.append(
                rpc(
                    "eth_sendTransaction",
                    [
                        {
                            "from": actor,
                            "to": router,
                            "data": data,
                            "nonce": "0x0",
                            "gas": hex(gas_limit),
                            "gasPrice": "0x0",
                        }
                    ],
                )
            )
        blocks = []
        seen = []
        for _ in range(100):
            rpc("evm_mine")
            block = rpc("eth_getBlockByNumber", ["latest", False])
            current = block["transactions"]
            assert current, "Pending queue made no progress"
            assert current == hashes[len(seen) : len(seen) + len(current)], (
                "FIFO block order changed"
            )
            receipts = batch([("eth_getTransactionReceipt", [h]) for h in current])
            assert all(r["status"] == "0x1" for r in receipts), (name, receipts)
            used = sum(int(r["gasUsed"], 16) for r in receipts)
            assert used == int(block["gasUsed"], 16) <= BLOCK_GAS
            assert int(block["gasLimit"], 16) == BLOCK_GAS
            blocks.append(
                {
                    "number": int(block["number"], 16),
                    "hash": block["hash"],
                    "transactions": len(current),
                    "gasUsed": used,
                    "gasLimit": BLOCK_GAS,
                }
            )
            seen += current
            if len(seen) == 100:
                break
        assert seen == hashes
        receipts = batch([("eth_getTransactionReceipt", [h]) for h in hashes])
        incoming = []
        fills = []
        for i, r in enumerate(receipts):
            logs = [
                event for event in r["logs"] if event["address"].lower() == hook.lower()
            ]
            created = [event for event in logs if event["topics"][0] == CREATE]
            matched = [event for event in logs if event["topics"][0] == MATCH]
            assert len(created) == 1 and len(matched) == depth, (
                name,
                i,
                len(created),
                len(matched),
            )
            incoming.append(created[0]["topics"][2])
            expected = makers[i * depth : (i + 1) * depth]
            for event, (_, order_id, quote) in zip(matched, expected):
                assert event["topics"][1].lower() == pool.lower()
                assert (
                    event["topics"][2 if resting_sell else 3].lower()
                    == order_id.lower()
                ), "Price/FIFO priority changed"
                assert (
                    event["topics"][3 if resting_sell else 2].lower()
                    == incoming[-1].lower()
                )
                assert int(event["data"][2:66], 16) == SIZE and int(
                    event["data"][66:], 16
                ) == int(quote)
            fills.extend(matched)
        checks = []
        expected = []
        for _, order_id, _ in makers:
            checks.append(
                call(hook, calldata("asyncOrder(bytes32,bytes32)", pool, order_id))
            )
            expected.append(0)
        for order_id in incoming:
            checks.append(
                call(hook, calldata("asyncOrder(bytes32,bytes32)", pool, order_id))
            )
            expected.append(0)
        for actor, _, quote in makers:
            amount = int(quote) if resting_sell else SIZE
            checks.append(
                call(
                    manager,
                    calldata(
                        "balanceOf(address,uint256)",
                        actor,
                        TOKEN1 if resting_sell else TOKEN0,
                    ),
                )
            )
            expected.append(amount - amount // 5000)
        for i, (actor, _) in enumerate(commands):
            amounts = [
                SIZE if resting_sell else int(m[2])
                for m in makers[i * depth : (i + 1) * depth]
            ]
            checks.append(
                call(
                    manager,
                    calldata(
                        "balanceOf(address,uint256)",
                        actor,
                        TOKEN0 if resting_sell else TOKEN1,
                    ),
                )
            )
            expected.append(sum(amount - amount // 5000 for amount in amounts))
        for token in [TOKEN0, TOKEN1]:
            checks.append(
                call(manager, calldata("balanceOf(address,uint256)", hook, token))
            )
            expected.append(0)
        checks.append(
            call(manager, calldata("balanceOf(address,uint256)", vault, TOKEN0))
        )
        expected.append(len(makers) * (SIZE // 5000))
        checks.append(
            call(manager, calldata("balanceOf(address,uint256)", vault, TOKEN1))
        )
        expected.append(
            sum(int(m[2]) // 5000 for m in makers) + (len(makers) + 100) * BID
        )
        for start in range(0, len(checks), 200):
            actual = [int(v, 16) for v in batch(checks[start : start + 200])]
            assert actual == expected[start : start + 200], (
                "Final accounting mismatch",
                name,
                start,
                [
                    (i, x, y)
                    for i, (x, y) in enumerate(
                        zip(actual, expected[start : start + 200])
                    )
                    if x != y
                ][:5],
            )
        for is_buy in [0, 1]:
            assert (
                int(
                    rpc(
                        "eth_call",
                        [
                            {
                                "to": hook,
                                "data": calldata(
                                    "bestOrder(bytes32,bool)", pool, is_buy
                                ),
                            },
                            "latest",
                        ],
                    )[2:66],
                    16,
                )
                == 0
            )
        values = [int(r["gasUsed"], 16) for r in receipts]
        result = {
            "workload": name,
            "incomingTransactions": 100,
            "matchesPerTransaction": depth,
            "matchedPairs": len(fills),
            "distinctIncomingOwners": 100,
            "restingOrders": len(makers),
            "initialGasEstimate": estimate,
            "transactionGasLimit": gas_limit,
            "totalReceiptGas": sum(values),
            "minReceiptGas": min(values),
            "maxReceiptGas": max(values),
            "meanReceiptGas": sum(values) / 100,
            "fits100InOneBlock": len(blocks) == 1,
            "blockCount": len(blocks),
            "blocks": blocks,
            "assertions": {
                "priceAndFifo": True,
                "exactMatchAmounts": True,
                "allOrdersClosed": True,
                "makerAndTakerNetClaims": True,
                "exactProtocolFeesAndBids": True,
                "zeroHookEscrow": True,
                "emptyBook": True,
            },
            "fixtureSha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
            "receipts": receipts,
        }
        # Keep full receipts without adding tens of megabytes of repeated log JSON to the diff.
        archive = gzip.compress(
            json.dumps(result, separators=(",", ":")).encode(), mtime=0
        )
        (OUT / f"{name}.json.gz").write_bytes(archive)
        print(
            name,
            "blocks",
            len(blocks),
            "first block tx",
            blocks[0]["transactions"],
            "total gas",
            sum(values),
            "matches",
            len(fills),
            flush=True,
        )
        return {k: v for k, v in result.items() if k != "receipts"}
    finally:
        process.terminate()
        process.wait(timeout=10)


selected = [m for m in sorted(metas) if a.workload is None or m[0] == a.workload]
assert selected
results = [measure(m) for m in selected]
summary = {
    "blockGasLimit": BLOCK_GAS,
    "chainId": 31337,
    "hardfork": "cancun",
    "compiler": subprocess.check_output(["hnc", "--version"], text=True).strip(),
    "fixtureCompiler": "solc 0.8.26",
    "solidityReferenceCommit": "3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89",
    "optimizerRuns": 10000,
    "forge": subprocess.check_output(["forge", "--version"], text=True).strip(),
    "anvil": subprocess.check_output(["anvil", "--version"], text=True).strip(),
    "sourceCommit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip(),
    "sourceDirty": bool(subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=ROOT, text=True
    ).strip()),
    "sourceSha256": {
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((ROOT / "src").rglob("*.huff"))
    },
    "gasLimitPolicy": "120% of the first transaction estimate, rounded up to 1000; fixed per workload. Block admission also requires remaining gas to cover this limit.",
    "scope": "Isolated local Anvil, controlled 18/6-decimal ERC20 fixtures, no LP liquidity, no live fork or public network writes. Setup excluded; receipts include intrinsic gas and refunds. Packing is measured for the stated gas-limit policy, not a universal maximum or wall-clock TPS.",
    "measurements": results,
}
(OUT / ("summary.json" if not a.workload else "partial-summary.json")).write_text(
    json.dumps(summary, indent=2) + "\n"
)
