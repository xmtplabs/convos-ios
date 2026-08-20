import { describe, expect, it } from "vitest";
import { constantTimeEqual, isValidRequestId, isValidReturnToken } from "../src/capabilities";
import { isValidGrokBotSessionToken, normalizedGrokBotAgents } from "../src/grokbot-input";

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

describe("Grok Bot bridge input", () => {
  it("accepts only high-entropy session capabilities", () => {
    expect(isValidGrokBotSessionToken(`grok_session_${"a".repeat(48)}`)).toBe(true);
    expect(isValidGrokBotSessionToken("grok_session_short")).toBe(false);
    expect(isValidGrokBotSessionToken(`grok_session_${"a".repeat(47)}/`)).toBe(false);
  });

  it("normalizes uniquely named gateway agents", () => {
    expect(
      normalizedGrokBotAgents([
        { id: "hamilton", name: " Hamilton ", title: "Operator", description: "Gets things done" },
        { id: "cto", name: "CTO" },
      ]),
    ).toEqual([
      { id: "hamilton", name: "Hamilton", title: "Operator", description: "Gets things done" },
      { id: "cto", name: "CTO", title: undefined, description: undefined },
    ]);
  });

  it("rejects duplicate agent ids", () => {
    expect(
      normalizedGrokBotAgents([
        { id: "hamilton", name: "Hamilton" },
        { id: "hamilton", name: "Hamilton Copy" },
      ]),
    ).toBeNull();
  });
});
