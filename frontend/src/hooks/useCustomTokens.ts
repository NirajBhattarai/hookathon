"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  CUSTOM_TOKENS_STORAGE_KEY,
  loadCustomTokens,
  saveCustomToken,
  toFaucetToken,
  type CustomToken,
} from "@/lib/customTokens";

export function useCustomTokens() {
  const [tokens, setTokens] = useState<CustomToken[]>([]);

  const refresh = useCallback(() => {
    setTokens(loadCustomTokens());
  }, []);

  useEffect(() => {
    refresh();
    const onStorage = (e: StorageEvent) => {
      if (e.key === CUSTOM_TOKENS_STORAGE_KEY) refresh();
    };
    const onCustom = () => refresh();
    window.addEventListener("storage", onStorage);
    window.addEventListener("binbook-custom-tokens", onCustom);
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("binbook-custom-tokens", onCustom);
    };
  }, [refresh]);

  const addToken = useCallback(
    (token: CustomToken) => {
      saveCustomToken(token);
      refresh();
    },
    [refresh]
  );

  const faucetTokens = useMemo(() => tokens.map(toFaucetToken), [tokens]);

  return { tokens, faucetTokens, addToken, refresh };
}
