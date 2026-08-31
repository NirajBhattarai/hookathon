import { describe, expect, it } from "vitest";
import {
  displayQuotePerBase,
  humanPoolPriceToRaw,
  poolPriceFromQuotePerBase,
  quotePerBaseToRawPoolPrice,
  rawPoolPriceToHuman,
  rawPoolPriceToQuotePerBase,
} from "./priceMath";

describe("pool price orientation", () => {
  it("passes through when pick-base is currency0", () => {
    expect(poolPriceFromQuotePerBase(2000, true)).toBe(2000);
    expect(displayQuotePerBase(2000, true)).toBe(2000);
  });

  it("inverts when pick-base is currency1", () => {
    expect(poolPriceFromQuotePerBase(2000, false)).toBeCloseTo(1 / 2000);
    expect(displayQuotePerBase(1 / 2000, false)).toBeCloseTo(2000);
  });

  it("round-trips user quote-per-base through pool price", () => {
    const user = 3500;
    const pool = poolPriceFromQuotePerBase(user, false);
    expect(displayQuotePerBase(pool, false)).toBeCloseTo(user);
  });
});

describe("decimal-aware pool price", () => {
  it("scales USDC (6) / PEPE (18): 100 PEPE per 1 USDC", () => {
    expect(humanPoolPriceToRaw(100, 6, 18)).toBe(100 * 10 ** 12);
    expect(rawPoolPriceToHuman(100 * 10 ** 12, 6, 18)).toBeCloseTo(100);
  });

  it("is a no-op when decimals match", () => {
    expect(quotePerBaseToRawPoolPrice(2, true, 18, 18)).toBe(2);
    expect(rawPoolPriceToQuotePerBase(2, true, 18, 18)).toBe(2);
  });

  it("round-trips quote-per-base through raw pool price", () => {
    const raw = quotePerBaseToRawPoolPrice(100, true, 6, 18);
    expect(rawPoolPriceToQuotePerBase(raw, true, 6, 18)).toBeCloseTo(100);
  });
});
