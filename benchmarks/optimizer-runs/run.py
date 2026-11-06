#!/usr/bin/env python3
"""Measure solc run-count tradeoffs on the pinned Solidity Router receipt workloads."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

PIN = "3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89"
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("repository", type=Path)
p.add_argument("--runs", default="1,200,1000,1337,10000,100000")
p.add_argument("--forge", default="forge")
a = p.parse_args()
repo = a.repository.resolve()
assert (
    subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    == PIN
)
runner = repo / "benchmarks/crossing/run.py"
results = []
for runs in map(int, a.runs.split(",")):
    output = ROOT / "benchmarks/optimizer-runs/results" / str(runs)
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, FOUNDRY_OPTIMIZER_RUNS=str(runs))
    with (output / "benchmark.log").open("w") as log:
        subprocess.run(
            ["python3", str(runner), "--output-dir", str(output)],
            cwd=repo,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    summary = json.loads((output / "summary.json").read_text())
    sizes = {}
    for name in [
        "AsyncSwap",
        "Router",
        "AsyncMatching",
        "IncomingMatching",
        "TickPrice",
        "TickBitmap",
    ]:
        artifact = json.loads(
            (repo / f".local/crossing/out/{name}.sol/{name}.json").read_text()
        )
        metadata = artifact.get("metadata") or json.loads(artifact["rawMetadata"])
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        # The upstream receipt runner labels 10,000 statically. Verify actual compilation before relabeling.
        assert metadata["settings"]["optimizer"]["runs"] == runs
        code = artifact["deployedBytecode"]["object"].removeprefix("0x")
        sizes[name] = len(code) // 2
    summary["optimizerRuns"] = runs
    summary["verifiedRuntimeBytes"] = sizes
    summary["benchmarkRunnerSha256"] = hashlib.sha256(runner.read_bytes()).hexdigest()
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    with (output / "reference-tests.json").open("w") as log:
        subprocess.run(
            [
                a.forge,
                "test",
                "--match-contract",
                "^(MatchingReferenceTest|IncomingMemoryReferenceTest)$",
                "--fuzz-runs",
                "256",
                "--json",
            ],
            cwd=repo,
            env=env,
            stdout=log,
            check=True,
        )
    tests = json.loads((output / "reference-tests.json").read_text())
    checks = [
        t for suite in tests.values() for t in suite.get("test_results", {}).values()
    ]
    assert checks and all(t["status"] == "Success" for t in checks)
    row = {
        "runs": runs,
        "runtimeBytes": sizes,
        "fitsEip170": all(n <= 24576 for n in sizes.values()),
        "referenceTestsPassed": len(checks),
        "meanReceiptGas": {
            m["workload"]: m["meanReceiptGas"] for m in summary["measurements"]
        },
        "totalReceiptGas": sum(m["totalReceiptGas"] for m in summary["measurements"]),
    }
    results.append(row)
    (ROOT / "benchmarks/optimizer-runs/results/summary.json").write_text(
        json.dumps(
            {
                "solidityCommit": PIN,
                "settings": "solc 0.8.26, optimizer enabled, Cancun; only optimizer runs vary",
                "results": results,
            },
            indent=2,
        )
        + "\n"
    )
    print(runs, row["totalReceiptGas"], sizes, flush=True)
