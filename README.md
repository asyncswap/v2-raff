# raff

A template for Uniswap v4 hooks written in [Huff](https://www.huff-neo.rs), compiled with
[huff-neo](https://github.com/cakevm/huff-neo) (`hnc`) and tested with Foundry.

## Layout

| Path | What it is |
| --- | --- |
| `src/Raff.huff` | The hook: dispatcher, constructor, modifiers, hook entry points, in-file `hnc` tests |
| `src/IHooks.huff`, `src/IAsyncSwap.huff`, `src/IRouter.huff` | Selectors, each checked by a test |
| `src/Assert.huff` | `ASSERT_EQ` and `REQUIRE` macros |
| `test/Raff.t.sol` | Foundry tests: compiles the hook with `foundry-huff-neo`, etches it at a flagged hook address |

## Setup

Install Foundry and huff-neo:

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup
curl -L https://raw.githubusercontent.com/cakevm/huff-neo/main/hnc-up/install | bash && hnc-up
```

Then clone with submodules:

```sh
git clone --recurse-submodules <your repo>
```

## Build and test

```sh
hnc src/Raff.huff -b        # creation bytecode
hnc src/Raff.huff test      # in-file Huff tests
forge test                  # Foundry tests (needs hnc on PATH; ffi is on in foundry.toml)
forge fmt --check
```

CI (`.github/workflows/test.yml`) runs all of these against the huff-neo release pinned in `HNC_VERSION`.
