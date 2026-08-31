import { describe, expect, it } from "vitest";
import { resolveUnseededBookAxis } from "./bins";
import { priceToSqrtPriceX96 } from "./priceMath";

describe("resolveUnseededBookAxis", () => {
  it("centers on the bin at price 1 with bin size 60", () => {
    const axis = resolveUnseededBookAxis(priceToSqrtPriceX96(1), 60, 10);
    expect(axis.currentBin).toBe(0);
    expect(axis.minBin).toBe(-10);
    expect(axis.maxBin).toBe(9);
  });

  it("derives a non-zero active bin for prices away from 1", () => {
    const axis = resolveUnseededBookAxis(priceToSqrtPriceX96(2), 60, 10);
    expect(axis.currentBin).not.toBe(0);
    expect(axis.minBin).toBe(axis.currentBin - 10);
    expect(axis.maxBin).toBe(axis.currentBin + 9);
  });
});
