"use client";

import Link from "next/link";
import { FormEvent, useState } from "react";
import { isAddress, parseUnits, type Address } from "viem";
import { useAccount, useDeployContract } from "wagmi";
import { NetworkGate } from "@/components/NetworkGate";
import { useAppPublicClient } from "@/hooks/useAppPublicClient";
import { useContractWrite } from "@/hooks/useContractWrite";
import { useCustomTokens } from "@/hooks/useCustomTokens";
import { useDeployment } from "@/hooks/useDeployment";
import { useResolvedConnector } from "@/hooks/useResolvedConnector";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { mockErc20Abi } from "@/lib/abi/mockErc20";
import { mockErc20Bytecode } from "@/lib/abi/mockErc20Bytecode";
import { shortenAddress } from "@/lib/bins";
import { FAUCET_TOKENS } from "@/lib/tokens";

/** Fixed total supply minted to the deployer right after contract creation. */
const TOTAL_SUPPLY = "1000000000";
const DEFAULT_DECIMALS = "18";

function CopyButton({ text, label }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      className="chip chip-copy"
      onClick={() => {
        void navigator.clipboard?.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
    >
      {copied ? "✓ copied" : (label ?? shortenAddress(text as Address))}
    </button>
  );
}

export function CustomTokenPanel() {
  const { address, isConnected } = useAccount();
  const { deployment, targetChainId } = useDeployment();
  const publicClient = useAppPublicClient(deployment);
  const connector = useResolvedConnector();
  const { tokens, addToken } = useCustomTokens();

  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [decimals, setDecimals] = useState(DEFAULT_DECIMALS);
  const [status, setStatus] = useState<string | null>(null);
  const [phase, setPhase] = useState<"idle" | "deploy" | "mint">("idle");

  const [importAddr, setImportAddr] = useState("");
  const [importStatus, setImportStatus] = useState<string | null>(null);

  const [deployedAddr, setDeployedAddr] = useState<Address | null>(null);
  const deployedMeta = useTokenMeta(deployedAddr ?? undefined);
  const importMeta = useTokenMeta(
    isAddress(importAddr) ? (importAddr as Address) : undefined
  );

  const { deployContractAsync } = useDeployContract();
  const { writeContractAsync } = useContractWrite();

  async function onCreate(e: FormEvent) {
    e.preventDefault();
    setStatus(null);
    if (!isConnected || !address) {
      setStatus("Connect your wallet first");
      return;
    }
    if (!publicClient) {
      setStatus("Network not ready — try again in a moment");
      return;
    }
    const nm = name.trim();
    const sym = symbol.trim().toUpperCase();
    const dec = Number(decimals);
    if (!nm) {
      setStatus("Enter a token name");
      return;
    }
    if (!sym || sym.length > 11) {
      setStatus("Enter a symbol (max 11 characters)");
      return;
    }
    if (!Number.isInteger(dec) || dec < 0 || dec > 18) {
      setStatus("Decimals must be 0–18");
      return;
    }

    try {
      setDeployedAddr(null);
      setPhase("deploy");
      const deployHash = await deployContractAsync({
        abi: mockErc20Abi,
        bytecode: mockErc20Bytecode,
        args: [nm, sym, dec],
        connector,
        chainId: targetChainId,
      });
      const deployReceipt = await publicClient.waitForTransactionReceipt({
        hash: deployHash,
        timeout: 120_000,
      });
      const tokenAddr = deployReceipt.contractAddress;
      if (!tokenAddr) {
        setStatus("Deploy succeeded but no contract address returned");
        return;
      }

      setPhase("mint");
      const mintHash = await writeContractAsync({
        address: tokenAddr,
        abi: mockErc20Abi,
        functionName: "mint",
        args: [address, parseUnits(TOTAL_SUPPLY, dec)],
      });
      await publicClient.waitForTransactionReceipt({ hash: mintHash, timeout: 120_000 });

      setDeployedAddr(tokenAddr);
      addToken({
        address: tokenAddr,
        symbol: sym,
        name: nm,
        decimals: dec,
        createdAt: Date.now(),
      });
      setStatus(
        `${sym} deployed with 1B total supply minted to your wallet — create a pool in Liquidity.`
      );
    } catch (err) {
      setStatus(err instanceof Error ? err.message.slice(0, 120) : "Deploy failed");
    } finally {
      setPhase("idle");
    }
  }

  const importReady =
    isAddress(importAddr) && !!importMeta.symbol && importMeta.decimals !== undefined;

  function onImport(e: FormEvent) {
    e.preventDefault();
    setImportStatus(null);
    if (!isAddress(importAddr)) {
      setImportStatus("Enter a valid token address (0x…)");
      return;
    }
    if (!importMeta.symbol || importMeta.decimals === undefined) {
      setImportStatus("Could not read token metadata — check the address and network");
      return;
    }
    addToken({
      address: importAddr as Address,
      symbol: importMeta.symbol,
      name: importMeta.symbol,
      decimals: importMeta.decimals,
      createdAt: Date.now(),
    });
    setImportStatus(`${importMeta.symbol} imported — pick it in Liquidity to create a pool`);
    setImportAddr("");
  }

  const busy = phase !== "idle";
  const defaultQuote = FAUCET_TOKENS.find((t) => t.symbol === "WETH") ?? FAUCET_TOKENS[4];

  return (
    <section className="page-wrap">
      <div className="faucet-hero">
        <div className="faucet-hero-glow" aria-hidden />
        <span className="faucet-drip-icon" aria-hidden>
          <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
            <path
              d="M12 3l8 8v2a7 7 0 1 1-14 0v-2l8-8z"
              stroke="currentColor"
              strokeWidth="1.5"
              fill="none"
            />
            <circle cx="12" cy="14" r="2.5" fill="currentColor" />
          </svg>
        </span>
        <h1 className="faucet-title">
          Launch a <em>custom token</em>
        </h1>
        <p className="faucet-sub">
          Deploy your own ERC-20 on Sepolia, copy the contract address, then pair it with any faucet
          token in Liquidity to create a BinBook pool.
        </p>
        <div className="faucet-chips">
          <span className="chip chip-accent">● Sepolia testnet</span>
          <span className="chip">1B fixed supply</span>
        </div>
      </div>

      <NetworkGate blockChildren>
        <div className="custom-token-grid">
          <form className="form-card" onSubmit={onCreate}>
            <h2 className="panel-title">Create token</h2>
            <p className="muted tiny" style={{ marginTop: 0 }}>
              Deploys a standard ERC-20 and mints 1,000,000,000 tokens to your wallet in the same
              flow.
            </p>

            <div className="form-grid">
              <div className="field">
                <label htmlFor="token-name">Name</label>
                <input
                  id="token-name"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="My Token"
                  disabled={busy}
                />
              </div>
              <div className="field">
                <label htmlFor="token-symbol">Symbol</label>
                <input
                  id="token-symbol"
                  value={symbol}
                  onChange={(e) => setSymbol(e.target.value.toUpperCase())}
                  placeholder="MTK"
                  maxLength={11}
                  disabled={busy}
                />
              </div>
              <div className="field">
                <label htmlFor="token-decimals">Decimals</label>
                <input
                  id="token-decimals"
                  value={decimals}
                  onChange={(e) => setDecimals(e.target.value)}
                  inputMode="numeric"
                  disabled={busy}
                />
              </div>
              <div className="field">
                <label>Total supply</label>
                <p className="muted tiny" style={{ margin: 0 }}>
                  1,000,000,000 tokens (minted to you on deploy)
                </p>
              </div>

              <button type="submit" className="cta" disabled={!isConnected || busy}>
                {!isConnected
                  ? "Connect wallet"
                  : phase === "deploy"
                    ? "Deploying…"
                    : phase === "mint"
                      ? "Minting 1B supply…"
                      : "Deploy & mint 1B"}
              </button>
              {status && <p className="status ok">{status}</p>}
            </div>
          </form>

          <form className="form-card" onSubmit={onImport}>
            <h2 className="panel-title">Import token</h2>
            <p className="muted tiny" style={{ marginTop: 0 }}>
              Already deployed? Paste the contract address to add it to your token list.
            </p>

            <div className="form-grid">
              <div className="field">
                <label htmlFor="import-addr">Contract address</label>
                <input
                  id="import-addr"
                  value={importAddr}
                  onChange={(e) => setImportAddr(e.target.value.trim())}
                  placeholder="0x…"
                  spellCheck={false}
                />
                {isAddress(importAddr) && importMeta.symbol && (
                  <p className="field-hint">
                    Detected: {importMeta.symbol} · {importMeta.decimals} decimals
                  </p>
                )}
              </div>
              <button type="submit" className="cta secondary" disabled={!importReady}>
                Import token
              </button>
              {importStatus && <p className="status ok">{importStatus}</p>}
            </div>
          </form>
        </div>

        {deployedAddr && (
          <div className="form-card custom-token-result">
            <h2 className="panel-title">Your new token</h2>
            <div className="custom-token-result-row">
              <div>
                <strong>{deployedMeta.symbol ?? symbol}</strong>
                <span className="muted tiny block">{name}</span>
              </div>
              <CopyButton text={deployedAddr} label="Copy address" />
            </div>
            <p className="mono tiny muted" style={{ wordBreak: "break-all", margin: "0.5rem 0 0" }}>
              {deployedAddr}
            </p>
            <Link
              href={`/liquidity?token=${deployedAddr}&quote=${defaultQuote?.address ?? ""}`}
              className="cta"
              style={{ marginTop: "1rem", display: "inline-block", textDecoration: "none" }}
            >
              Create liquidity pool →
            </Link>
          </div>
        )}

        {tokens.length > 0 && (
          <div className="form-card" style={{ marginTop: "1.25rem" }}>
            <h2 className="panel-title">Your tokens</h2>
            <ul className="custom-token-list">
              {tokens.map((t) => (
                <li key={t.address} className="custom-token-row">
                  <div className="custom-token-row-id">
                    <span className="token-avatar" style={{ background: "#7c5cff" }}>
                      {t.symbol.slice(0, 1)}
                    </span>
                    <div>
                      <strong>{t.symbol}</strong>
                      <span className="muted tiny block">{t.name}</span>
                    </div>
                  </div>
                  <div className="custom-token-row-actions">
                    <CopyButton text={t.address} />
                    <Link
                      href={`/liquidity?token=${t.address}&quote=${defaultQuote?.address ?? ""}`}
                      className="chip chip-accent"
                    >
                      Create pool
                    </Link>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        )}
      </NetworkGate>
    </section>
  );
}
