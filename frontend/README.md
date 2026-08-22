# BinBook Frontend

Next.js App Router UI for the BinBook Uniswap v4 hook.

## Stack

- Reown AppKit (`@reown/appkit`)
- wagmi + viem
- Chain config via env (switch networks without code changes)

## Setup

1. Copy env and add your Reown project id from https://dashboard.reown.com

```bash
cp .env.example .env.local
```

2. Fill `NEXT_PUBLIC_REOWN_PROJECT_ID` and per-chain addresses (`NEXT_PUBLIC_BINBOOK_<id>`, tokens, router, pool manager).

3. Install and run:

```bash
npm install
npm run dev
```

## Switch chains

Edit `.env.local`:

```bash
NEXT_PUBLIC_ENABLED_CHAINS=31337,11155111,1
NEXT_PUBLIC_DEFAULT_CHAIN_ID=11155111
```

Add addresses for each chain id you enable. Known chains: `31337` (Anvil), `11155111` (Sepolia), `1` (mainnet). To support another chain, extend `CHAIN_BY_ID` in `src/config/chains.ts`.

## Sync ABI after contract changes

```bash
# from smartcontract/
forge build
# from frontend/
npm run sync-abi
```
