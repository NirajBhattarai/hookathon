'use client'

import { FormEvent, useState } from 'react'
import { parseUnits, type Address } from 'viem'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { binBookAbi } from '@/lib/abi/binBook'
import { useDeployment } from '@/hooks/useDeployment'
import { usePool } from '@/hooks/usePool'
import { BinDepthChart } from '@/components/BinDepthChart'

const erc20Abi = [
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ type: 'bool' }],
  },
] as const

type Preset = 'spot' | 'custom'

export function AddLiquidityForm() {
  const { address, isConnected } = useAccount()
  const { deployment, ready } = useDeployment()
  const { key } = usePool()
  const preview = !ready
  const [amount0, setAmount0] = useState('1')
  const [amount1, setAmount1] = useState('1')
  const [tickLower, setTickLower] = useState('0')
  const [tickUpper, setTickUpper] = useState('0')
  const [preset, setPreset] = useState<Preset>('spot')
  const [status, setStatus] = useState<string | null>(null)

  const { writeContractAsync, data: hash, isPending } = useWriteContract()
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash })

  function applyPreset(next: Preset) {
    setPreset(next)
    if (next === 'spot') {
      setTickLower('0')
      setTickUpper('0')
    }
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (preview) {
      setStatus('Preview mode — add BinBook + token addresses to submit.')
      return
    }
    if (!deployment || !address || !key) return
    setStatus(null)
    try {
      const a0 = parseUnits(amount0 || '0', 18)
      const a1 = parseUnits(amount1 || '0', 18)
      if (a0 > 0n) {
        await writeContractAsync({
          address: deployment.token0,
          abi: erc20Abi,
          functionName: 'approve',
          args: [deployment.binBook, a0],
        })
      }
      if (a1 > 0n) {
        await writeContractAsync({
          address: deployment.token1,
          abi: erc20Abi,
          functionName: 'approve',
          args: [deployment.binBook, a1],
        })
      }
      await writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: 'addLiquidity',
        args: [
          key!,
          {
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0n,
            amount1Min: 0n,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower: Number(tickLower),
            tickUpper: Number(tickUpper),
            userInputSalt: ('0x' + '00'.repeat(32)) as `0x${string}`,
          },
        ],
      })
      setStatus('Liquidity submitted')
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Failed')
    }
  }

  const cta = preview
    ? 'Preview add liquidity'
    : !isConnected
      ? 'Connect wallet'
      : isPending || confirming
        ? 'Confirm in wallet…'
        : 'Add liquidity'

  return (
    <div className="trade-layout">
      <div className="page-wrap" style={{ maxWidth: 460, width: '100%', margin: 0 }}>
        <h1 className="page-title">Add liquidity</h1>
        <p className="page-sub">Deposit into the bin book. Near-spot uses the default ramp window.</p>

        <form className={preview ? 'form-card preview' : 'form-card'} onSubmit={onSubmit}>
          {preview && (
            <div style={{ marginBottom: '0.75rem' }}>
              <span className="badge">Preview</span>
            </div>
          )}

          <div className="form-grid">
            <div>
              <div className="field" style={{ marginBottom: '0.5rem' }}>
                <label>Range</label>
              </div>
              <div className="range-presets">
                <button
                  type="button"
                  className={preset === 'spot' ? 'preset active' : 'preset'}
                  onClick={() => applyPreset('spot')}
                >
                  Near spot
                </button>
                <button
                  type="button"
                  className={preset === 'custom' ? 'preset active' : 'preset'}
                  onClick={() => applyPreset('custom')}
                >
                  Custom ticks
                </button>
              </div>
            </div>

            <div className="token-field">
              <div className="token-field-top">
                <span>TOKEN0</span>
              </div>
              <div className="token-field-row">
                <input
                  value={amount0}
                  onChange={(e) => setAmount0(e.target.value)}
                  inputMode="decimal"
                  placeholder="0"
                />
              </div>
            </div>

            <div className="token-field">
              <div className="token-field-top">
                <span>TOKEN1</span>
              </div>
              <div className="token-field-row">
                <input
                  value={amount1}
                  onChange={(e) => setAmount1(e.target.value)}
                  inputMode="decimal"
                  placeholder="0"
                />
              </div>
            </div>

            {preset === 'custom' && (
              <div className="row-2">
                <div className="field">
                  <label>tickLower</label>
                  <input value={tickLower} onChange={(e) => setTickLower(e.target.value)} />
                </div>
                <div className="field">
                  <label>tickUpper</label>
                  <input value={tickUpper} onChange={(e) => setTickUpper(e.target.value)} />
                </div>
              </div>
            )}

            <button
              type="submit"
              className="cta"
              disabled={!preview && (isPending || confirming)}
            >
              {cta}
            </button>

            {status && <p className="status">{status}</p>}
            {preview && (
              <p className="preview-note">UI only until BinBook + tokens are configured.</p>
            )}
            {!preview && deployment && (
              <p className="preview-note">
                Hook {(deployment.binBook as Address).slice(0, 10)}…
              </p>
            )}
          </div>
        </form>
      </div>
      <BinDepthChart />
    </div>
  )
}
