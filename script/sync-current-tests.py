#!/usr/bin/env python3
"""Pin the Solidity suite and generate Huff deployment adapters without changing assertions."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from current_adapters import supported, adapt_formal

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89"
SNAPSHOT = ROOT / "reference/contracts"
ADAPTED = ROOT / "compat/current/test"
EXCLUDED = {
    "test/Numeraire.t.sol": "Constructor tests inherit Solidity AsyncSwap; needs a Huff constructor adapter.",
    "test/BaseHookDefaults.t.sol": "Tests a Solidity BaseHook subclass, not a deployed protocol module.",
    "test/IndexLibraryDeployment.t.sol": "Solidity linked-library deployment scripts.",
    "test/IncomingLibraryDeployment.t.sol": "Solidity linked-library deployment script.",
    "test/TickBitmap.t.sol": "Direct Solidity library harness; needs an independent Huff harness.",
    "test/TickPriceKey.t.sol": "Direct Solidity library harness; needs an independent Huff harness.",
    "test/TickPricePoolBeatsLevel.t.sol": "Direct Solidity library harness; needs an independent Huff harness.",
    "test/RadixPriceTree.t.sol": "Direct Solidity library harness; legacy Huff has a separate radix suite.",
    "test/EligiblePrice.t.sol": "Uses Solidity internal/storage-layout harnesses.",
    "test/security/ClaimTransfers.t.sol": "Direct Solidity library harness.",
    "test/security/PriorityPythonHashes.t.sol": "Direct Solidity signature-library harness.",
    "test/security/FeeClaims.t.sol": "Overrides a Solidity hook method; needs a Huff surcharge adapter.",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def ending(text, opening):
    """Find the closing parenthesis, skipping Solidity strings and comments."""
    depth = 0
    i = opening
    while i < len(text):
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
        elif text.startswith("/*", i):
            i = text.index("*/", i + 2) + 2
        elif text[i] in "\"'":
            quote = text[i]
            i += 1
            while text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    return i
            i += 1
    raise ValueError("Unbalanced constructor/deployment call")


def adapt(text):
    changes = []
    pattern = r"\bnew\s+(Router|NativeClaims|TokenClaims|MatchingEngine)\s*\("
    while match := re.search(pattern, text):
        end = ending(text, match.end() - 1)
        name = match[1]
        args = text[match.end() : end]
        source = f"src/current/{name}.huff" if name == "Router" else f"src/{name}.huff"
        deploy = f'CurrentHuffDeploy.deploy("{source}", abi.encode({args}))'
        replacement = (
            f"{name}(payable({deploy}))" if name == "Router" else f"{name}({deploy})"
        )
        text = text[: match.start()] + replacement + text[end + 1 :]
        changes.append(f"deploy {name} as Huff")
    pattern = r'\bdeployCodeTo\s*\(\s*"AsyncSwap.sol"\s*,'
    text, count = re.subn(pattern, "CurrentHuffDeploy.hookTo(", text)
    changes += ["deploy AsyncSwap as Huff"] * count
    # Keep the Solidity types as ABI bindings; imports cannot change the deployed bytecode.
    text = re.sub(r'"src/([^"\n]+\.sol)"', r'"@async-swap/\1"', text)
    text = re.sub(r'"(?:\.\./)+src/([^"\n]+\.sol)"', r'"@async-swap/\1"', text)
    text = text.replace(
        '"test/utils/MockERC20.sol:MockERC20"',
        '"compat/current/test/utils/MockERC20.sol:MockERC20"',
    )
    if changes:
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\n\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";'
            + text[pos:]
        )
    return text, changes


def assertion_calls(text):
    # Keep behavioral assertions, revert/event expectations and fuzz assumptions byte-equivalent
    # apart from formatting. Deployment and storage fixture adaptations cannot weaken this gate.
    calls = []
    for match in re.finditer(
        r"\b(?:assert[A-Z]\w*|expectRevert|expectEmit|expectCall|assume)\s*\(", text
    ):
        end = ending(text, match.end() - 1)
        calls.append(re.sub(r"\s+", "", text[match.start() : end + 1]))
    return calls


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "repository", type=Path, help="Local asyncswap/contracts Git checkout"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify every snapshot/adapter byte without writing",
    )
    parser.add_argument(
        "--forge", default="forge", help="Forge formatter executable (CI pins v1.8.6)"
    )
    args = parser.parse_args()
    repo = args.repository.resolve()
    paths = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", COMMIT, "src", "test"],
        cwd=repo,
        text=True,
    ).splitlines()
    expected = {}
    manifest = {
        "repository": "https://github.com/asyncswap/contracts",
        "commit": COMMIT,
        "sourceFiles": {},
        "huffAdapters": {},
        "referenceOnly": {},
    }
    for path in paths:
        data = subprocess.check_output(["git", "show", f"{COMMIT}:{path}"], cwd=repo)
        expected[SNAPSHOT / path] = data
        manifest["sourceFiles"][path] = sha(data)
        if not path.startswith("test/") or not path.endswith(".sol"):
            continue
        text = data.decode()
        parts = Path(path).parts
        reason = EXCLUDED.get(path)
        if "/formal/" in text:
            reason = "Depends on Solidity internal/storage-layout harnesses."
        if len(parts) > 2 and parts[1] not in ("security", "utils"):
            reason = (
                "Specialized Solidity/internal harness; retained verbatim as reference."
            )
        if supported(path):
            reason = None
        if reason:
            manifest["referenceOnly"][path] = reason
            continue
        transformed, changes = adapt(text)
        transformed, extra_changes = adapt_formal(path, transformed)
        changes += extra_changes
        assert assertion_calls(text) == assertion_calls(transformed), (
            f"Behavioral assertion changed: {path}"
        )
        transformed = (
            subprocess.check_output(
                [args.forge, "fmt", "--raw", "-"],
                input=transformed,
                cwd=ROOT,
                text=True,
            ).rstrip()
            + "\n"
        )
        # Refuse to silently test an inherited Solidity implementation as if it were Huff.
        assert not re.search(
            r"\bis\s+(?:AsyncSwap|Router|NativeClaims|TokenClaims)\b", transformed
        ), path
        assert not re.search(
            r"\bnew\s+(?:AsyncSwap|Router|NativeClaims|TokenClaims|MatchingEngine)\s*\(",
            transformed,
        ), path
        target = ADAPTED / Path(path).relative_to("test")
        expected[target] = transformed.encode()
        manifest["huffAdapters"][path] = {
            "sha256": sha(expected[target]),
            "deploymentChanges": changes,
            "assertionsSha256": sha("\n".join(assertion_calls(text)).encode()),
        }
    expected[ROOT / "compat/current/manifest.json"] = (
        json.dumps(manifest, indent=2) + "\n"
    ).encode()
    for path, data in expected.items():
        if args.check:
            assert path.exists() and path.read_bytes() == data, (
                f"Snapshot/adapter changed: {path.relative_to(ROOT)}"
            )
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    actual = set(SNAPSHOT.rglob("*")) | set(ADAPTED.rglob("*"))
    extra = [p for p in actual if p.is_file() and p not in expected]
    assert not extra, f"Unexpected files in generated directories: {extra}"
    print(
        f"{'Verified' if args.check else 'Copied'} {len(paths)} pinned files; {len(manifest['huffAdapters'])} Huff test/support adapters; {len(manifest['referenceOnly'])} Solidity-only files retained separately."
    )


if __name__ == "__main__":
    main()
