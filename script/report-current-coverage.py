#!/usr/bin/env python3
"""Inventory upstream tests by identity, counting grouped invariant predicates individually."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument(
    "--source-list",
    type=Path,
    required=True,
    help="Pinned forge test --no-match-test ^$ --list --json",
)
p.add_argument(
    "--huff-list",
    type=Path,
    required=True,
    help="Current-profile forge test --no-match-test ^$ --list --json",
)
p.add_argument(
    "--results",
    type=Path,
    required=True,
    help="Current-profile forge test --json result",
)
a = p.parse_args()


def identities(path):
    d = json.loads(path.read_text())
    return {
        (f.replace("compat/current/test/", "test/", 1), c, t)
        for f, cs in d.items()
        for c, ts in cs.items()
        for t in ts
    }


source = identities(a.source_list)
huff = identities(a.huff_list)
assert huff <= source, "An adapter introduces tests absent from the pinned source"
results = json.loads(a.results.read_text())
executed = {}
for suite, data in results.items():
    f, c = suite.split(":")
    f = f.replace("compat/current/test/", "test/", 1)
    for t, r in data["test_results"].items():
        predicates = r.get("invariant_predicate_results") or [
            {"name": t.split("(")[0], "status": r["status"]}
        ]
        for item in predicates:
            executed[(f, c, item["name"])] = item["status"]
assert set(executed) == huff, (
    "Missing execution/predicate results; do not count discovery as coverage"
)
assert all(v == "Success" for v in executed.values())
manifest = json.loads((ROOT / "compat/current/manifest.json").read_text())
rows = []
for f, c, t in sorted(source):
    adapted = (f, c, t) in huff
    rows.append(
        {
            "file": f,
            "contract": c,
            "test": t,
            "status": "passed-huff"
            if adapted
            else "excluded-finding"
            if "_finding_" in t
            else "reference-only",
            "reason": None
            if adapted
            else manifest["referenceOnly"].get(f, "Not adapted"),
        }
    )
report = {
    "solidityCommit": manifest["commit"],
    "sourceTestsIncludingFindings": len(source),
    "upstreamFindingTests": sum("_finding_" in t for f, c, t in source),
    "passedHuffTestsAndPredicates": len(executed),
    "forgeResultEntries": sum(len(d["test_results"]) for d in results.values()),
    "unportedRunnableTests": sum(r["status"] == "reference-only" for r in rows),
    "note": "Foundry groups invariant predicates into one result per suite. All individual predicate statuses are checked. Discovery and imported Solidity-only helpers are not counted as execution.",
    "tests": rows,
}
(ROOT / "compat/current/results/coverage.json").write_text(
    json.dumps(report, indent=2) + "\n"
)
print({k: v for k, v in report.items() if k != "tests"})
