'use client'

import { FormEvent, useMemo, useState } from 'react'
import { parseUnits, type Address } from 'viem'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useDeployment } from '@/hooks/useDeployment'
import { poolKeyFor } from '@/lib/pool'

const swapRouterAbi = [
  {
    type: 'function',
    name: 'swapExactTokensForTokens',
    stateMutability: 'payable',
    inputs: [
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOutMin', type: 'uint256' },
      { name: 'zeroForOne', type: 'bool' },
      {
        name: 'poolKey',
        type: 'tuple',
        components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'hookData', type: 'bytes' },
      { name: 'receiver', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
] as const

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

function TokenPill({ symbol, alt }: { symbol: string; alt?: boolean }) {
  return (
    <span className="token-pill">
      <span className={alt ? 'token-dot alt' : 'token-dot'} />
      {symbol}
    </span>
  )
}

export function SwapForm() {
  const { address, isConnected } = useAccount()
  const { deployment, ready } = useDeployment()
  const preview = !ready
  const [amountIn, setAmountIn] = useState('1')
  const [zeroForOne, setZeroForOne] = useState(true)
  const [slippage, setSlippage] = useState('0.50')
  const [status, setStatus] = useState<string | null>(null)

  const { writeContractAsync, data: hash, isPending } = useWriteContract()
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash })

  const paySymbol = zeroForOne ? 'TOKEN0' : 'TOKEN1'
  const receiveSymbol = zeroForOne ? 'TOKEN1' : 'TOKEN0'

  // Preview quote: simple 1:1 with fee for UI polish
  const estimatedOut = useMemo(() => {
    const n = Number(amountIn)
    if (!Number.isFinite(n) || n <= 0) return '0'
    const fee = (deployment?.poolFee ?? 3000) / 1_000_000
    return (n * (1 - fee)).toFixed(6)
  }, [amountIn, deployment?.poolFee])

  const ctaLabel = useMemo(() => {
    if (preview) return 'Preview swap'
    if (!isConnected) return 'Connect wallet'
    if (isPending || confirming) return 'Confirm in wallet…'
    if (!amountIn || Number(amountIn) <= 0) return 'Enter an amount'
    return 'Swap'
  }, [preview, isConnected, isPending, confirming, amountIn])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (preview) {
      setStatus('Preview mode — add router + token addresses to go live.')
      return
    }
    if (!deployment || !address) return
    setStatus(null)
    try {
      const value = parseUnits(amountIn || '0', 18)
      const tokenIn = zeroForOne ? deployment.token0 : deployment.token1
      await writeContractAsync({
        address: tokenIn,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployment.swapRouter, value],
      })
      await writeContractAsync({
        address: deployment.swapRouter,
        abi: swapRouterAbi,
        functionName: 'swapExactTokensForTokens',
        args: [
          value,
          0n,
          zeroForOne,
          poolKeyFor(deployment),
          '0x',
          address,
          BigInt(Math.floor(Date.now() / 1000) + 600),
        ],
      })
      setStatus('Swap submitted')
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Swap failed')
    }
  }

  return (
    <form className={preview ? 'swap-card preview' : 'swap-card'} onSubmit={onSubmit}>
      <div className="swap-card-top">
        <h1>Swap</h1>
        {preview && <span className="badge">Preview</span>}
      </div>

      <div className="token-field">
        <div className="token-field-top">
          <span>You pay</span>
          <div className="balance-row">
            <span>Balance —</span>
            <button type="button" className="chip" onClick={() => setAmountIn('1')}>
              Max
            </button>
          </div>
        </div>
        <div className="token-field-row">
          <input
            value={amountIn}
            onChange={(e) => setAmountIn(e.target.value)}
            inputMode="decimal"
            placeholder="0"
            aria-label="Amount in"
          />
          <TokenPill symbol={paySymbol} alt={!zeroForOne} />
        </div>
        <div className="fiat-hint">≈ $—</div>
      </div>

      <div className="swap-flip-wrap">
        <button
          type="button"
          className="flip-btn"
          onClick={() => setZeroForOne((v) => !v)}
          aria-label="Flip tokens"
        >
          ↓
        </button>
      </div>

      <div className="token-field">
        <div className="token-field-top">
          <span>You receive</span>
          <span>Balance —</span>
        </div>
        <div className="token-field-row">
          <input value={estimatedOut} readOnly tabIndex={-1} aria-label="Amount out estimate" />
          <TokenPill symbol={receiveSymbol} alt={zeroForOne} />
        </div>
        <div className="fiat-hint">≈ $— · est. after fee</div>
      </div>

      <details className="details" open>
        <summary>
          <span>
            1 {paySymbol} ≈ {(1 - (deployment?.poolFee ?? 3000) / 1_000_000).toFixed(4)} {receiveSymbol}
          </span>
          <span>Details</span>
        </summary>
        <div className="details-body">
          <div className="detail-row">
            <span>Fee tier</span>
            <span>{((deployment?.poolFee ?? 3000) / 10000).toFixed(2)}%</span>
          </div>
          <div className="detail-row">
            <span>Max slippage</span>
            <span>
              <input
                value={slippage}
                onChange={(e) => setSlippage(e.target.value)}
                style={{
                  width: '3.5rem',
                  background: 'transparent',
                  border: '0',
                  color: 'inherit',
                  textAlign: 'right',
                }}
                aria-label="Slippage percent"
              />
              %
            </span>
          </div>
          <div className="detail-row">
            <span>Minimum received</span>
            <span>
              {(
                Number(estimatedOut) *
                (1 - (Number(slippage) || 0.5) / 100)
              ).toFixed(6)}{' '}
              {receiveSymbol}
            </span>
          </div>
          <div className="detail-row">
            <span>Route</span>
            <span>BinBook hook</span>
          </div>
        </div>
      </details>

      <button
        type="submit"
        className="cta"
        disabled={!preview && (isPending || confirming || !amountIn || Number(amountIn) <= 0)}
      >
        {ctaLabel}
      </button>

      {status && <p className="status">{status}</p>}
      {preview && (
        <p className="preview-note">UI preview — wire router + tokens in .env.local to execute.</p>
      )}
      {!preview && deployment && (
        <p className="preview-note">
          Router {(deployment.swapRouter as Address).slice(0, 10)}…
        </p>
      )}
    </form>
  )
}
