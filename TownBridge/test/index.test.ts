import { describe, expect, it } from "vitest";
import { constantTimeEqual, isValidRequestId, isValidReturnToken } from "../src/capabilities";

describe("request capabilities", () => {
  it("accepts URL-safe identifiers of the expected length", () => {
    expect(isValidRequestId("request_12345678901234567890")).toBe(true);
    expect(isValidReturnToken("return_token_123456789012345678901234567890")).toBe(true);
  });

  it("rejects short or unsafe capability values", () => {
    expect(isValidRequestId("short")).toBe(false);
    expect(isValidRequestId("request/12345678901234567890")).toBe(false);
    expect(isValidReturnToken("token with spaces that is deliberately long")).toBe(false);
  });

  it("compares equal hashes without accepting prefixes", () => {
    expect(constantTimeEqual("abc123", "abc123")).toBe(true);
    expect(constantTimeEqual("abc123", "abc1234")).toBe(false);
    expect(constantTimeEqual("abc123", "abc124")).toBe(false);
  });
});
