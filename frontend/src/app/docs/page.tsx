"use client";

import { useEffect, useRef } from "react";

/**
 * Product architecture / performance walkthrough. Content mirrors README.md at the repo root —
 * this page exists so it's reachable from the live app itself, not just GitHub.
 */

const PERF_DATA = [
  { label: "0.5%", xyk: 1.34, bin: -0.44 },
  { label: "1%", xyk: 3.19, bin: -0.29 },
  { label: "2%", xyk: 6.61, bin: 0.02 },
  { label: "3%", xyk: 9.72, bin: 0.32 },
  { label: "5%", xyk: 15.08, bin: 0.97 },
  { label: "10%", xyk: 24.81, bin: 2.78 },
] as const;

const PLOT_H = 210; // must match .docs-bar-col's fixed height in globals.css
const ZERO_Y = 145; // px from the top of the plot area
const LABEL_PAD = 16;
const NEG_REFERENCE = 1; // % — loss bars are tiny; scale against this, not maxXyk, so they still read

function BinScopeCanvas() {
  const ref = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const W = canvas.width;
    const H = canvas.height;
    const BINS = 21;
    const CENTER = Math.floor(BINS / 2);
    const RAMP = CENTER + 1;

    function binDistance(i: number) {
      // mirrors BinLayout.binDistance: the active bin sits at distance 1, not 0
      return i < CENTER ? CENTER - i : i - CENTER + 1;
    }

    function heightFor(i: number, t: number) {
      const d = binDistance(i);
      const L = Math.max(0, (RAMP - d) / RAMP);
      const breathe = reduceMotion ? 1 : 1 + 0.04 * Math.sin(t / 900 + i * 0.5);
      return L * breathe;
    }

    function colors() {
      const cs = getComputedStyle(document.documentElement);
      return {
        line: cs.getPropertyValue("--line").trim(),
        accent: cs.getPropertyValue("--accent").trim(),
        muted2: cs.getPropertyValue("--muted-2").trim(),
      };
    }

    let raf = 0;

    function draw(t: number) {
      const c = colors();
      ctx!.clearRect(0, 0, W, H);

      const baseline = H - 30;
      const top = 24;
      const usable = baseline - top;
      const gap = 4;
      const bw = (W - gap * (BINS - 1)) / BINS;

      ctx!.strokeStyle = c.line;
      ctx!.lineWidth = 1;
      ctx!.beginPath();
      ctx!.moveTo(0, baseline + 0.5);
      ctx!.lineTo(W, baseline + 0.5);
      ctx!.stroke();

      for (let i = 0; i < BINS; i++) {
        const h = heightFor(i, t) * usable;
        const x = i * (bw + gap);
        const y = baseline - h;
        const isActive = i === CENTER;
        ctx!.fillStyle = c.accent;
        ctx!.globalAlpha = isActive ? 1 : 0.4 + 0.4 * (h / usable);
        if (h > 0.5) ctx!.fillRect(x, y, bw, h);
      }
      ctx!.globalAlpha = 1;

      const driftPeriod = 3400;
      const drift = reduceMotion ? 0.5 : (Math.sin(t / driftPeriod) + 1) / 2;
      const activeX = CENTER * (bw + gap);
      const markerX = activeX + drift * bw;

      ctx!.strokeStyle = c.accent;
      ctx!.lineWidth = 1.5;
      ctx!.setLineDash([3, 3]);
      ctx!.beginPath();
      ctx!.moveTo(markerX, top - 8);
      ctx!.lineTo(markerX, baseline);
      ctx!.stroke();
      ctx!.setLineDash([]);

      ctx!.fillStyle = c.accent;
      ctx!.beginPath();
      ctx!.arc(markerX, top - 8, 3, 0, Math.PI * 2);
      ctx!.fill();

      ctx!.fillStyle = c.muted2;
      ctx!.font = "10px monospace";
      ctx!.textAlign = "center";
      ctx!.fillText("active price", markerX, top - 14);
    }

    if (reduceMotion) {
      draw(0);
    } else {
      const loop = (ts: number) => {
        draw(ts);
        raf = requestAnimationFrame(loop);
      };
      raf = requestAnimationFrame(loop);
    }

    return () => cancelAnimationFrame(raf);
  }, []);

  return <canvas id="docsBinScope" ref={ref} width={560} height={320} />;
}

function PerfChart() {
  const maxXyk = Math.max(...PERF_DATA.map((d) => d.xyk));
  const posScale = (ZERO_Y - LABEL_PAD) / maxXyk;
  const negScale = (PLOT_H - ZERO_Y - LABEL_PAD) / NEG_REFERENCE;

  return (
    <div className="docs-chart">
      {PERF_DATA.map((d, i) => {
        const xykH = d.xyk * posScale;
        const isNeg = d.bin < 0;
        const binH = Math.abs(d.bin) * (isNeg ? negScale : posScale);
        return (
          <div className="docs-bar-col" key={d.label}>
            <div className="docs-bars">
              <div
                className="docs-bar xyk grow-up"
                style={{ height: xykH, top: ZERO_Y - xykH, animationDelay: `${i * 70 + 200}ms` }}
              >
                <span className="docs-bar-val">+{d.xyk.toFixed(2)}%</span>
              </div>
              <div
                className={`docs-bar bin${isNeg ? " neg grow-down" : " grow-up"}`}
                style={{
                  height: binH,
                  top: isNeg ? ZERO_Y : ZERO_Y - binH,
                  animationDelay: `${i * 70 + 200}ms`,
                }}
              >
                <span className="docs-bar-val">
                  {d.bin >= 0 ? "+" : ""}
                  {d.bin.toFixed(2)}%
                </span>
              </div>
            </div>
            <div className="docs-bar-label">{d.label}</div>
          </div>
        );
      })}
      <div className="docs-chart-zero" style={{ top: ZERO_Y }} />
    </div>
  );
}

const ARCH_SVG_LABEL =
  "Architecture diagram: the frontend calls BinBook, which exchanges hook callbacks and unlock/settle calls with the Uniswap v4 PoolManager, and calls into the pure BinLayout and SwapMath libraries for book geometry and swap/value math respectively.";

function ArchitectureDiagram() {
  return (
    <svg
      viewBox="0 0 920 360"
      role="img"
      aria-label={ARCH_SVG_LABEL}
      style={{ width: "100%", height: "auto" }}
    >
      <defs>
        <marker
          id="docsArrow"
          viewBox="0 0 10 10"
          refX="8"
          refY="5"
          markerWidth="7"
          markerHeight="7"
          orient="auto-start-reverse"
        >
          <path d="M0,0 L10,5 L0,10 z" fill="currentColor" />
        </marker>
      </defs>
      <g fill="none" stroke="currentColor" strokeWidth="1.2" opacity="0.85" fontSize="12.5">
        <rect x="20" y="150" width="150" height="64" rx="6" />
        <text x="95" y="177" textAnchor="middle" fill="currentColor" stroke="none" fontWeight="600">
          Frontend
        </text>
        <text x="95" y="195" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10.5" opacity="0.65">
          Next.js · wagmi/viem
        </text>

        <rect
          x="260"
          y="118"
          width="220"
          height="128"
          rx="6"
          stroke="var(--accent)"
          strokeWidth="1.8"
        />
        <text x="370" y="146" textAnchor="middle" fill="currentColor" stroke="none" fontWeight="600">
          BinBook.sol
        </text>
        <text x="370" y="163" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10.5" opacity="0.7">
          hook + accounting
        </text>
        <text x="370" y="182" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10" opacity="0.55">
          createPool
        </text>
        <text x="370" y="198" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10" opacity="0.55">
          add / removeLiquidity
        </text>
        <text x="370" y="214" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10" opacity="0.55">
          collectFees · swap
        </text>

        <rect x="640" y="150" width="180" height="64" rx="6" />
        <text x="730" y="177" textAnchor="middle" fill="currentColor" stroke="none" fontWeight="600">
          PoolManager
        </text>
        <text x="730" y="195" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10.5" opacity="0.65">
          Uniswap v4 core
        </text>

        <rect x="240" y="288" width="200" height="58" rx="6" />
        <text x="340" y="312" textAnchor="middle" fill="currentColor" stroke="none" fontWeight="600" fontSize="12">
          BinLayout.sol
        </text>
        <text x="340" y="330" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10" opacity="0.6">
          book geometry
        </text>

        <rect x="500" y="288" width="200" height="58" rx="6" />
        <text x="600" y="312" textAnchor="middle" fill="currentColor" stroke="none" fontWeight="600" fontSize="12">
          SwapMath.sol
        </text>
        <text x="600" y="330" textAnchor="middle" fill="currentColor" stroke="none" fontSize="10" opacity="0.6">
          swap &amp; value math
        </text>

        <line x1="170" y1="182" x2="256" y2="182" markerEnd="url(#docsArrow)" />
        <text x="213" y="174" textAnchor="middle" fill="currentColor" stroke="none" fontSize="9.5" opacity="0.7">
          ABI calls
        </text>

        <line x1="480" y1="170" x2="636" y2="170" markerEnd="url(#docsArrow)" />
        <line x1="636" y1="196" x2="480" y2="196" markerEnd="url(#docsArrow)" />
        <text x="558" y="152" textAnchor="middle" fill="currentColor" stroke="none" fontSize="9.5" opacity="0.7">
          before* callbacks
        </text>
        <text x="558" y="216" textAnchor="middle" fill="currentColor" stroke="none" fontSize="9.5" opacity="0.7">
          unlock / settle
        </text>

        <line x1="345" y1="246" x2="342" y2="284" markerEnd="url(#docsArrow)" />
        <text x="300" y="270" textAnchor="middle" fill="currentColor" stroke="none" fontSize="9.5" opacity="0.7">
          resolveBinRange
        </text>

        <line x1="480" y1="230" x2="592" y2="284" markerEnd="url(#docsArrow)" />
        <text x="560" y="262" textAnchor="middle" fill="currentColor" stroke="none" fontSize="9.5" opacity="0.7">
          computeSwapStep, valueOf
        </text>
      </g>
    </svg>
  );
}

export default function DocsPage() {
  return (
    <main className="docs-wrap">
      <header className="docs-hero">
        <div>
          <p className="docs-eyebrow">Uniswap v4 hook · hook-owned liquidity book</p>
          <h1>
            Liquidity, <em>binned</em>
            <br />
            and ramped to price.
          </h1>
          <p className="lead">
            BinBook replaces v4&apos;s native tick-range positions with fixed-width bins around the
            active price, sized by a linear-decay ramp — most depth right at spot, tapering to
            nothing at the edges. The hook owns every position; you deposit, it distributes.
          </p>
          <div className="docs-cta-row">
            <a
              className="primary"
              href="https://github.com/NirajBhattarai/hookathon"
              target="_blank"
              rel="noopener noreferrer"
            >
              View source ↗
            </a>
            <a href="#performance">See the sandwich data ↓</a>
          </div>
        </div>
        <div className="docs-scope-panel">
          <div className="docs-scope-head">
            <span>book depth</span>
            <span className="tag">illustrative</span>
          </div>
          <BinScopeCanvas />
          <div className="docs-scope-foot">
            <span>ramp: linear decay</span>
            <span className="tabular">bin size · 60 ticks</span>
          </div>
        </div>
      </header>

      <section className="docs-section" id="mechanism">
        <div className="docs-section-head">
          <p className="docs-eyebrow">Architecture</p>
          <h2>Three files, one ledger.</h2>
          <p>
            The hook owns all state. Two libraries do the math — one for book geometry, one for
            the swap curve and share pricing — and never touch storage themselves.
          </p>
        </div>
        <div className="docs-diagram-panel">
          <ArchitectureDiagram />
          <p className="docs-diagram-caption">
            BinBook is the only stateful contract; BinLayout and SwapMath are pure libraries it
            calls into, never the other way around.
          </p>
        </div>
      </section>

      <section className="docs-section" id="concepts">
        <div className="docs-section-head">
          <p className="docs-eyebrow">Core concepts</p>
          <h2>Five decisions that shape the book.</h2>
        </div>
        <div className="docs-concept-grid">
          <div className="docs-concept-card">
            <div className="idx">01 — geometry</div>
            <h3>Bins, not ticks</h3>
            <p>
              Each pool fixes a <code>binSize</code> (ticks per bin) at creation. Liquidity lives
              per <code>(pool, bin)</code> — a far smaller state space to walk on every swap and
              withdrawal than arbitrary tick ranges.
            </p>
          </div>
          <div className="docs-concept-card">
            <div className="idx">02 — sizing</div>
            <h3>Linear decay</h3>
            <p>
              A deposit peaks in the bin closest to the active price and decays linearly to the
              edges of the requested range. No manual shaping — the ramp does it.
            </p>
          </div>
          <div className="docs-concept-card">
            <div className="idx">03 — ownership</div>
            <h3>Hook-owned positions</h3>
            <p>
              v4 sees BinBook as the sole liquidity provider. Underneath, it keeps its own
              per-user, per-bin ledger — <code>positions[poolId][user][binIndex]</code>.
            </p>
          </div>
          <div className="docs-concept-card">
            <div className="idx">04 — accounting</div>
            <h3>Price-aware shares</h3>
            <p>
              Shares mint and burn against a token0-equivalent value (
              <code>SwapMath.valueOf</code>) at the live price — not a raw{" "}
              <code>amount0 + amount1</code> sum, which misprices a deposit by which token it
              landed in.
            </p>
          </div>
          <div className="docs-concept-card span-2">
            <div className="idx">05 — withdrawal</div>
            <h3>
              Range-scoped <code>removeLiquidity</code>
            </h3>
            <p>
              Withdrawals and fee collection are scoped to the caller&apos;s chosen{" "}
              <code>[tickLower, tickUpper]</code> — converted to a bin range and value-targeted
              against a pool-wide price snapshot — so a withdrawal costs what the requested range
              costs, not everything the caller has ever touched in that pool.
            </p>
          </div>
        </div>
      </section>

      <section className="docs-section" id="performance">
        <div className="docs-section-head">
          <p className="docs-eyebrow">Performance · measured, not claimed</p>
          <h2>Why bins beat x·y=k for a meme launch.</h2>
          <p>
            A launch pool is thin and one-sided — the first target for sandwich bots.{" "}
            <code>test_sandwich_meme_sweep</code> runs the identical sandwich (2× front-run,
            victim trade, back-run) against two pools with matching TVL and fee — one plain
            x·y=k, one BinBook — across trade sizes from 0.5% to 10% of TVL.
          </p>
        </div>

        <div className="docs-perf-layout">
          <div className="docs-chart-panel">
            <div className="docs-chart-title">
              <span>Attacker ROI by trade size</span>
              <span className="tabular">30bps fee · ~3% bins</span>
            </div>
            <PerfChart />
            <div className="docs-legend">
              <span>
                <i className="docs-swatch" style={{ background: "var(--muted-2)" }} /> x·y=k
              </span>
              <span>
                <i className="docs-swatch" style={{ background: "var(--up)" }} /> BinBook (profit)
              </span>
              <span>
                <i className="docs-swatch" style={{ background: "var(--down)" }} /> BinBook (loss)
              </span>
            </div>
          </div>

          <div className="docs-stat-block">
            <div className="docs-stat">
              <div className="num loss">−0.44%</div>
              <div className="lab">
                attacker ROI sandwiching a 0.5%-of-TVL trade — a guaranteed loss, not just a
                smaller profit
              </div>
            </div>
            <div className="docs-stat">
              <div className="num">100%</div>
              <div className="lab">of x·y=k&apos;s sandwich profit erased below ~1% of TVL</div>
            </div>
            <div className="docs-stat">
              <div className="num">88.8%</div>
              <div className="lab">profit cut even at 10% of TVL, the sweep&apos;s largest trade</div>
            </div>
          </div>
        </div>

        <p className="docs-mech-note">
          <strong>Why:</strong> the decay ramp concentrates depth in a shallow slice of bins right
          at the active price instead of spreading it across the whole curve. An attacker&apos;s
          front-run of a given size walks through far less depth, so it moves price — and burns
          fee — disproportionately more than the same trade would on a flat x·y=k curve. That
          extra cost lands on the attacker&apos;s own front-run before the back-run ever happens.
        </p>

        <div className="docs-repro">
          <div className="docs-repro-label">Reproduce</div>
          <pre className="docs-cmd">forge test --match-test test_sandwich_meme_sweep -vv</pre>
        </div>
      </section>

      <section className="docs-section" id="tests">
        <div className="docs-section-head">
          <p className="docs-eyebrow">Verification</p>
          <h2>One test file per concern.</h2>
        </div>
        <div className="docs-table-wrap">
          <table className="docs-table">
            <thead>
              <tr>
                <th>File</th>
                <th>Covers</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>
                  <code>BinBook.createpool.t.sol</code>
                </td>
                <td className="covers">
                  The <code>createPool</code> gateway: bin size validation, currency ordering,
                  hook binding
                </td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.liquidity.t.sol</code>
                </td>
                <td className="covers">
                  <code>addLiquidity</code>/<code>removeLiquidity</code> mechanics, reverts,
                  range-scoping
                </td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.fees.t.sol</code>
                </td>
                <td className="covers">Fee accrual and <code>collectFees</code></td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.swap.t.sol</code>
                </td>
                <td className="covers">Swap execution against the book</td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.shares.stress.t.sol</code>
                </td>
                <td className="covers">
                  Share-accounting fairness under many providers / full withdrawals
                </td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.sandwich.t.sol</code>, <code>regimes.t.sol</code>
                </td>
                <td className="covers">
                  Sandwich resistance and price-regime behavior vs. a plain x·y=k curve
                </td>
              </tr>
              <tr>
                <td>
                  <code>BinBook.mintManipulation.t.sol</code>
                </td>
                <td className="covers">
                  Regression: spot-price share minting can&apos;t be gamed via
                  swap→deposit→swap-back
                </td>
              </tr>
              <tr>
                <td>
                  <code>libraries/BinLayout.t.sol</code>, <code>SwapMath.t.sol</code>
                </td>
                <td className="covers">Pure library unit/fuzz tests</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <p className="docs-footer-note">
        A hook-owned, discretized liquidity book for Uniswap v4. Built with Foundry.
      </p>
    </main>
  );
}
