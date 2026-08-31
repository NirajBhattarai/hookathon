import type { Address } from "viem";
import type { FaucetToken } from "@/lib/tokens";

export const CUSTOM_TOKENS_STORAGE_KEY = "binbook-custom-tokens";

export type CustomToken = {
  address: Address;
  symbol: string;
  name: string;
  decimals: number;
  createdAt: number;
};

function isAddress(v: unknown): v is Address {
  return typeof v === "string" && /^0x[a-fA-F0-9]{40}$/.test(v);
}

export function loadCustomTokens(): CustomToken[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(CUSTOM_TOKENS_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (t): t is CustomToken =>
        !!t &&
        typeof t === "object" &&
        isAddress((t as CustomToken).address) &&
        typeof (t as CustomToken).symbol === "string" &&
        typeof (t as CustomToken).name === "string" &&
        typeof (t as CustomToken).decimals === "number"
    );
  } catch {
    return [];
  }
}

export function saveCustomToken(token: CustomToken): void {
  if (typeof window === "undefined") return;
  const existing = loadCustomTokens().filter(
    (t) => t.address.toLowerCase() !== token.address.toLowerCase()
  );
  const next = [token, ...existing];
  window.localStorage.setItem(CUSTOM_TOKENS_STORAGE_KEY, JSON.stringify(next));
  window.dispatchEvent(new Event("binbook-custom-tokens"));
}

export function toFaucetToken(token: CustomToken): FaucetToken {
  return {
    symbol: token.symbol,
    name: token.name,
    decimals: token.decimals,
    amountLabel: "",
    color: "#7c5cff",
    category: "DeFi",
    address: token.address,
  };
}
