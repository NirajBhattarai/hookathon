/** Stub — the real module pulls in @coinbase/cdp-sdk's x402 deps, which aren't installed and
 *  aren't needed: enableBaseAccount:false in context/index.tsx means this is never called. */
export function baseAccount() {
  throw new Error("Base Account connector is disabled in this app");
}
