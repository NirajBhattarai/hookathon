'use client'

import { useState } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { binBookAbi } from '@/lib/abi/binBook'
import { useDeployment } from '@/hooks/useDeployment'
import { usePool } from '@/hooks/usePool'

const WITHDRAW_PCTS = [25, 50, 100] as const

export function PortfolioPanel() {
  const { address, isConnected } = useAccount()
  const { deployment, ready } = useDeployment()
  const { key, poolId } = usePool()
  const preview = !ready
  const [status, setStatus] = useState<string | null>(null)
  const [withdrawPct, setWithdrawPct] = useState<number>(50)

  const sharesQ = useReadContract({
    address: deployment?.binBook,
    abi: binBookAbi,
    functionName: 'getShares',
    args: poolId && address ? [poolId, address] : undefined,
    query: { enabled: ready && !!poolId && !!address },
  })

  const supplyQ = useReadContract({
    address: deployment?.binBook,
    abi: binBookAbi,
    functionName: 'getTotalShares',
    args: poolId ? [poolId] : undefined,
    query: { enabled: ready && !!poolId },
  })

  const pendingQ = useReadContract({
    address: deployment?.binBook,
    abi: binBookAbi,
    functionName: 'pendingFees',
    args: poolId && address ? [poolId, address] : undefined,
    query: { enabled: ready && !!poolId && !!address },
  })

  const { writeContractAsync, data: hash, isPending } = useWriteContract()
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash })

  async function collect() {
    if (preview || !deployment || !key) {
      setStatus('Preview mode — add BinBook address to collect.')
      return
    }
    setStatus(null)
    try {
      await writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: 'collectFees',
        args: [key],
      })
      setStatus('Fees collected')
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Collect failed')
    }
  }

  async function withdraw() {
    if (preview || !deployment || !key) return
    const shares = sharesQ.data ?? 0n
    const amount = (shares * BigInt(withdrawPct)) / 100n
    if (amount === 0n) {
      setStatus('No shares to withdraw')
      return
    }
    setStatus(null)
    try {
      await writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: 'removeLiquidity',
        args: [
          key,
          {
            liquidity: amount,
            amount0Min: 0n,
            amount1Min: 0n,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: ('0x' + '00'.repeat(32)) as `0x${string}`,
          },
        ],
      })
      setStatus(`Withdrew ${withdrawPct}% of your position`)
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Withdraw failed')
    }
  }

  const fee0 = preview ? 1250000000000000n : pendingQ.data?.[0]
  const fee1 = preview ? 890000000000000n : pendingQ.data?.[1]
  const shareVal = preview ? 42n : sharesQ.data
  const supplyVal = preview ? 100n : supplyQ.data
  const sharePct =
    shareVal != null && supplyVal != null && supplyVal > 0n
      ? Number((shareVal * 10000n) / supplyVal) / 100
      : null

  return (
    <div className="page-wrap">
      <h1 className="page-title">Portfolio</h1>
      <p className="page-sub">Your shares and accrued fees across bins of the configured pool.</p>

      <div className={preview ? 'form-card preview' : 'form-card'}>
        {preview && (
          <div style={{ marginBottom: '0.85rem' }}>
            <span className="badge">Preview</span>
          </div>
        )}

        {!preview && !isConnected ? (
          <p className="muted">Connect a wallet to view positions.</p>
        ) : (
          <>
            <dl className="stats">
              <div>
                <dt>Pending fee0</dt>
                <dd>{fee0 != null ? fee0.toString() : '—'}</dd>
              </div>
              <div>
                <dt>Pending fee1</dt>
                <dd>{fee1 != null ? fee1.toString() : '—'}</dd>
              </div>
              <div>
                <dt>Shares</dt>
                <dd>{shareVal != null ? String(shareVal) : '—'}</dd>
              </div>
              <div>
                <dt>Pool share</dt>
                <dd>{sharePct != null ? `${sharePct.toFixed(2)}%` : '—'}</dd>
              </div>
            </dl>

            <button
              type="button"
              className="cta"
              onClick={collect}
              disabled={!preview && (isPending || confirming || !address)}
            >
              {preview ? 'Preview collect fees' : isPending || confirming ? 'Confirm…' : 'Collect fees'}
            </button>

            {!preview && (
              <>
                <div className="row-2" style={{ marginTop: '0.75rem' }}>
                  {WITHDRAW_PCTS.map((p) => (
                    <button
                      key={p}
                      type="button"
                      className={withdrawPct === p ? 'preset active' : 'preset'}
                      onClick={() => setWithdrawPct(p)}
                    >
                      Withdraw {p}%
                    </button>
                  ))}
                </div>
                <button
                  type="button"
                  className="cta"
                  style={{ marginTop: '0.5rem' }}
                  onClick={withdraw}
                  disabled={isPending || confirming || !address || (sharesQ.data ?? 0n) === 0n}
                >
                  {isPending || confirming ? 'Confirm…' : 'Remove liquidity'}
                </button>
              </>
            )}

            {status && <p className="status">{status}</p>}
            {preview && <p className="preview-note">Sample numbers until contracts are wired.</p>}
          </>
        )}
      </div>
    </div>
  )
}
