#!/usr/bin/env python3
"""Compare public-state checkpoints from two successful Forge -vvvv logs."""

import argparse
import re
from pathlib import Path


def read_trace(path, lp=False):
    text = path.read_text()
    if "Suite result: ok. 1 passed; 0 failed; 0 skipped" not in text:
        raise ValueError(f"{path}: expected a successful single-test run")
    event = "LPStateCheckpoint" if lp else "StateCheckpoint"
    steps = 65 if lp else 64
    actions = 11 if lp else 8
    checkpoints = re.findall(r"emit " + event + r"\(step: (\d+), digest: (0x[0-9a-f]{64})\)", text)
    if [int(step) for step, _ in checkpoints] != list(range(steps)):
        raise ValueError(f"{path}: expected exactly {steps} consecutive checkpoints")
    counts = re.findall(r"emit " + ("LPActionCount" if lp else "CampaignActionCount") + r"\(action: (\d+), successes: (\d+)\)", text)
    if [int(action) for action, _ in counts] != list(range(actions)):
        raise ValueError(f"{path}: missing action coverage")
    if any(int(n) == 0 for _, n in counts) or sum(int(n) for _, n in counts) != 64:
        raise ValueError(f"{path}: incomplete action coverage")
    return checkpoints, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("solidity_log", type=Path)
    parser.add_argument("huff_log", type=Path)
    parser.add_argument("--lp", action="store_true", help="Compare the LP campaign and final withdrawal checkpoint")
    args = parser.parse_args()
    left, left_counts = read_trace(args.solidity_log, args.lp)
    right, right_counts = read_trace(args.huff_log, args.lp)
    for a, b in zip(left, right):
        if a != b:
            raise SystemExit(f"State mismatch at step {a[0]}: Solidity {a[1]}, Huff {b[1]}")
    if left_counts != right_counts:
        raise SystemExit("Action coverage differs")
    print(f"PASS: all {len(left)} state checkpoints match; all {len(left_counts)} action types executed.")
    print("Action counts:", ", ".join(f"{a}={n}" for a, n in left_counts))


if __name__ == "__main__":
    main()
