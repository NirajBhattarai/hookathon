# BinBook — Smart Contracts

Foundry project for the `BinBook` Uniswap v4 hook. For the overall project architecture and
core concepts, see the [root README](../README.md).

## Repo layout

```
src/
  BinBook.sol              # the hook
  libraries/
    BinLayout.sol           # book geometry
    SwapMath.sol             # swap & value math
test/                        # Foundry unit, fuzz, and stress tests (see below)
script/                      # deployment & pool-setup scripts
```

### Test suite

One file per concern, mirroring `src/`:

| File | Covers |
|---|---|
| `BinBook.createpool.t.sol` | The `createPool` gateway: bin size validation, currency ordering, hook binding |
| `BinBook.liquidity.t.sol` | `addLiquidity`/`removeLiquidity` mechanics, reverts, range-scoping |
| `BinBook.fees.t.sol` | Fee accrual and `collectFees` |
| `BinBook.swap.t.sol` | Swap execution against the book |
| `BinBook.shares.stress.t.sol` | Share-accounting fairness under many providers / full withdrawals |
| `BinBook.sandwich.t.sol`, `BinBook.regimes.t.sol` | Sandwich resistance and price-regime behavior vs. a plain x·y=k curve |
| `BinBook.mintManipulation.t.sol` | Regression: spot-price share minting can't be gamed via swap→deposit→swap-back |
| `libraries/BinLayout.t.sol`, `libraries/SwapMath.t.sol` | Pure library unit/fuzz tests |

```bash
forge test
```

## Get Started

### Requirements

Built with Foundry (stable). If you're on Foundry Nightly, update to stable:

```bash
foundryup
```

Install dependencies and run the tests:

```bash
forge install
forge test
```

### Local Development

Deployment and pool-setup scripts live in `script/`; they work against a local
[anvil](https://book.getfoundry.sh/anvil/) node or a live network.

#### Anvil

1. Start Anvil (optionally forking a live chain):

```bash
anvil
# or
anvil --fork-url <YOUR_RPC_URL>
```

2. Run a script:

```bash
forge script script/binbook/00_DeployBinBook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

#### Live networks

Prefer a keystore over a raw private key on the command line:

```bash
cast wallet import <KEY_NAME> --interactive
```

```bash
forge script script/binbook/00_DeployBinBook.s.sol \
    --rpc-url <YOUR_RPC_URL> \
    --account <KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast
```

### Verifying the hook contract

```bash
forge verify-contract \
  --rpc-url <URL> \
  --chain <CHAIN_NAME_OR_ID> \
  --verifier <Verification_Provider> \
  --verifier-api-key <Verification_Provider_API_KEY> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --num-of-optimizations <OPTIMIZER_RUNS> \
  <Contract_Address> \
  <path/to/BinBook.sol:BinBook> \
  --watch
```

### Troubleshooting

<details>
<summary>Permission Denied on <code>forge install</code></summary>

Typically caused by missing GitHub SSH keys — see
[connecting to GitHub with SSH](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh),
or [add existing keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent).

</details>

<details>
<summary>Anvil fork test failures</summary>

Some Foundry versions limit contract code size to ~25kb. Raise it:

```bash
anvil --code-size-limit 40000
```

</details>

<details>
<summary>Hook deployment failures</summary>

Almost always incorrect flags or salt mining:

1. Verify `getHookPermissions()` returns the flags actually being mined for.
2. Verify the salt-mining deployer matches the actual deployer:
   - In **forge test**: `address(this)` (or the `vm.prank`-ed address).
   - In **forge script**: the CREATE2 proxy, `0x4e59b44847b379578588920cA78FbF26c0B4956C`. If
     anvil doesn't have it deployed, update with `foundryup`.

</details>

### Additional Resources

- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-periphery](https://github.com/uniswap/v4-periphery)
- [v4-core](https://github.com/uniswap/v4-core)
- [v4-by-example](https://v4-by-example.org)
