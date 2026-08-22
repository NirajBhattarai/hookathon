import { createConfig, http } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { readContract } from '@wagmi/core'

const RPC = 'https://sepolia.infura.io/v3/7cd4731a3be74a6ab7c32fe799ab3177'
const Q = '0xaBfb6a5F03FC9F12164B665F50F989ad53240520'
const ME = '0xE824B6B86D72fa45719E87BF9d6Ab3864C580654'

// VERBATIM from src/components/SwapForm.tsx
const binQuoterAbi = [
  {
    type: 'error',
    name: 'Quote',
    inputs: [
      { name: 'amount0', type: 'int128' },
      { name: 'amount1', type: 'int128' },
    ],
  },
  {
    type: 'function',
    name: 'quoteExactInput',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'p',
        type: 'tuple',
        components: [
          {
            name: 'key',
            type: 'tuple',
            components: [
              { name: 'currency0', type: 'address' },
              { name: 'currency1', type: 'address' },
              { name: 'fee', type: 'uint24' },
              { name: 'tickSpacing', type: 'int24' },
              { name: 'hooks', type: 'address' },
            ],
          },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'receiver', type: 'address' },
        ],
      },
    ],
    outputs: [],
  },
]

const config = createConfig({
  chains: [sepolia],
  transports: { [sepolia.id]: http(RPC) },
})

const key = {
  currency0: '0x4B8DFabf9389182F33eaaC56A8746fED88554E75',
  currency1: '0xdc21FDB62477277166410a23eA03eD3D43854e3e',
  fee: 3000,
  tickSpacing: 10,
  hooks: '0x12d591f01E17d9Be48eb0fa78Ad8b8d166dbbA88',
}

for (const z4o of [true, false]) {
  try {
    await readContract(config, {
      address: Q,
      abi: binQuoterAbi,
      functionName: 'quoteExactInput',
      args: [{ key, zeroForOne: z4o, amountIn: z4o ? 1000000n : 10n ** 16n, receiver: ME }],
    })
    console.log(`z4o=${z4o}: no error`)
  } catch (e) {
    console.log(`\n===== z4o=${z4o} =====`)
    let cur = e, depth = 0
    while (cur && depth < 8) {
      const d = cur?.data
      console.log(`depth ${depth}: ${cur?.name} data=${d ? JSON.stringify(d, (_, v) => typeof v === "bigint" ? v.toString() + "n" : v) : 'no'}`)
      cur = cur?.cause
      depth++
    }
  }
}
