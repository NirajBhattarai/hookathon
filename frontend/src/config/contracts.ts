import { deploymentFor, type ChainDeployment, type SupportedChainId } from "./chains";

/** Convenience re-export — resolve deployment for the active wallet chain. */
export function getContracts(chainId: number | undefined): ChainDeployment | null {
  if (chainId == null) return null;
  try {
    return deploymentFor(chainId);
  } catch {
    return null;
  }
}

export type { ChainDeployment, SupportedChainId };
