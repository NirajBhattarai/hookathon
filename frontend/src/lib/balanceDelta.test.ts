import { describe, expect, it } from "vitest";
import { asInt128, unpackBalanceDelta } from "./balanceDelta";

describe("asInt128", () => {
  it("passes through small positives", () => {
    expect(asInt128(42n)).toBe(42n);
  });

  it("sign-extends negative int128 packed in 256 bits", () => {
    const negOne = (1n << 128n) - 1n;
    expect(asInt128(negOne)).toBe(-1n);
  });
});

describe("unpackBalanceDelta", () => {
  it("unpacks positive principal deltas", () => {
    const delta = (100n << 128n) | 50n;
    expect(unpackBalanceDelta(delta)).toEqual([100n, 50n]);
  });

  it("returns absolute values for negative limbs", () => {
    const neg50 = (1n << 128n) - 50n;
    const delta = (200n << 128n) | neg50;
    expect(unpackBalanceDelta(delta)).toEqual([200n, 50n]);
  });
});
