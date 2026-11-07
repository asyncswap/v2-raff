#!/usr/bin/env python3
"""Copy the supplemental Solidity tests, changing only fixture import/artifact paths."""

import argparse
import hashlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("solidity_repository", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name in ("AdversarialAssumptions", "MultiPoolLiquidityAccounting", "TokenBalanceDelta", "ProtocolDeploymentSize"):
        source = args.solidity_repository / f"test/security/{name}.t.sol"
        text = source.read_text()
        adapted = text.replace('"../SetupHook.t.sol"', '"../test/SetupHook.t.sol"')
        adapted = adapted.replace('"../utils/MockERC20.sol"', '"../test/utils/MockERC20.sol"')
        adapted = adapted.replace(
            '"test/utils/MockERC20.sol:MockERC20"',
            '"compat/current/test/utils/MockERC20.sol:MockERC20"',
        )
        destination = ROOT / f"compat/current/adversarial/{name}.t.sol"
        if args.check:
            # Preserve string contents and every non-whitespace token; Forge may wrap longer paths.
            tokens = lambda value: re.findall(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\S', value)
            if tokens(destination.read_text()) != tokens(adapted):
                raise SystemExit("Supplemental tests differ beyond the three fixture path substitutions")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(adapted)
            subprocess.run(["forge", "fmt", str(destination)], check=True)
        print("PASS: test bodies and assertions unchanged; only fixture paths and formatting differ.")
        print(name + " source SHA-256:", hashlib.sha256(text.encode()).hexdigest())


if __name__ == "__main__":
    main()
