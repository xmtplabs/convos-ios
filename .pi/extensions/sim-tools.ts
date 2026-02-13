import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

const AGENT_URL = "http://localhost:8615";

interface UIElementInfo {
  identifier?: string;
  label?: string;
  value?: string;
  placeholderValue?: string;
  elementType: string;
  frame: { x: number; y: number; width: number; height: number };
  isEnabled: boolean;
  isHittable: boolean;
  isSelected: boolean;
  hasFocus: boolean;
}

interface ScreenState {
  elements: UIElementInfo[];
  focusedElement?: UIElementInfo;
  alerts: UIElementInfo[];
  navigationBars: string[];
  timestamp: number;
}

interface AgentResponse {
  success: boolean;
  message?: string;
  screenState?: ScreenState;
  tappedElement?: UIElementInfo;
  error?: string;
  durationMs?: number;
}

async function agentAction(
  action: string,
  params?: Record<string, any>,
  observe: boolean = false
): Promise<AgentResponse> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 60000);
  try {
    const resp = await fetch(`${AGENT_URL}/action`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, params, observe }),
      signal: controller.signal,
    });
    return resp.json();
  } finally {
    clearTimeout(timeoutId);
  }
}

function formatElement(el: UIElementInfo): string {
  const parts: string[] = [];
  if (el.identifier) parts.push(`id=${el.identifier}`);
  if (el.label) parts.push(`label="${el.label}"`);
  parts.push(`type=${el.elementType}`);
  parts.push(
    `center=(${Math.round(el.frame.x + el.frame.width / 2)},${Math.round(el.frame.y + el.frame.height / 2)})`
  );
  if (!el.isEnabled) parts.push("disabled");
  return parts.join(", ");
}

// System/keyboard identifiers to always hide
const SYSTEM_IDS = new Set([
  "inputView", "SystemInputAssistantView", "CenterPageView",
  "UIKeyboardLayoutStar Preview", "AdditionalDimmingOverlay",
  "dictation", "shift", "delete", "more", "space", "Return",
  "Done", "Toolbar", "checkmark",
]);

function isRelevant(el: UIElementInfo): boolean {
  const id = el.identifier || "";
  const label = el.label || "";

  // Hide system/keyboard noise
  if (SYSTEM_IDS.has(id)) return false;
  // Hide internal SwiftUI identifiers
  if (id.startsWith("_Tt")) return false;
  // Hide keyboard keys (single char, no id)
  if (!id && label.length === 1) return false;
  // Hide elements with no id and no label
  if (!id && !label) return false;
  // Hide system image names used as identifiers (SF Symbols)
  if (id && !id.includes("-") && id.includes(".") && !id.startsWith("qr")) return false;

  // Show app elements with identifiers (devs set these)
  if (id && id.includes("-")) return true;
  // Show buttons and interactive elements with labels
  if (label && ["button", "textField", "secureTextField", "textView",
    "searchField", "switch", "toggle", "slider", "popUpButton",
    "menuItem", "link", "cell"].includes(el.elementType)) return true;
  // Show staticText with labels that look like content (not timestamps, not single words under 3 chars)
  if (el.elementType === "staticText" && label.length > 3) return true;
  // Show alerts
  if (el.elementType === "alert" || el.elementType === "sheet") return true;
  return false;
}

function formatScreenState(state: ScreenState): string {
  const lines: string[] = [];
  const seenIds = new Set<string>();
  const seenLabels = new Set<string>();
  for (const el of state.elements) {
    const id = el.identifier || "";
    const label = el.label || "";
    if (!id && !label) continue;
    if (!isRelevant(el)) continue;
    // Dedup: if we already showed this id, skip
    if (id && seenIds.has(id)) continue;
    // Dedup: if no id but same label already shown, skip
    if (!id && label && seenLabels.has(label)) continue;
    if (id) seenIds.add(id);
    if (label) seenLabels.add(label);
    const enabled = el.isEnabled ? "" : " (disabled)";
    lines.push(
      `  ${(id || "(no id)").padEnd(30)} ${label.padEnd(40)} ${el.elementType}${enabled}`
    );
  }

  if (state.alerts.length > 0) {
    lines.push("\nAlerts:");
    for (const alert of state.alerts) {
      lines.push(`  ${alert.label || alert.identifier || "unknown alert"}`);
    }
  }

  return lines.join("\n");
}

export default function (pi: ExtensionAPI) {
  // --- tapElement: find + tap + return new screen state ---
  pi.registerTool({
    name: "sim_wait_and_tap",
    label: "Find element, tap it, return screen state",
    description:
      "Find an element by accessibility identifier or label, tap it, wait for the UI to settle, and return the resulting screen state. Replaces the wait-for-element + tap + describe pattern with a single call. Returns the tapped element info and all elements now on screen.",
    parameters: Type.Object({
      identifier: Type.Optional(
        Type.String({ description: "Accessibility identifier to find" })
      ),
      label: Type.Optional(
        Type.String({ description: "Exact label text to find" })
      ),
      labelContains: Type.Optional(
        Type.String({ description: "Substring of label to find" })
      ),
      timeout: Type.Optional(
        Type.Number({ description: "Max wait time in seconds (default: 5)" })
      ),
    }),
    async execute(_id, params) {
      // On failure, observe to show what's on screen
      const resp = await agentAction("tapElement", {
        identifier: params.identifier,
        label: params.label,
        labelContains: params.labelContains,
        timeout: params.timeout ?? 5,
      });

      if (!resp.success) {
        // Retry with observe to show available elements
        const obs = await agentAction("observeScreen", {}, true);
        let text = `Not found: ${params.identifier || params.label || params.labelContains}`;
        if (obs.screenState) {
          text += `\n\nScreen:\n${formatScreenState(obs.screenState)}`;
        }
        return {
          content: [{ type: "text" as const, text }],
          details: {},
          isError: true,
        };
      }

      let text = "Tapped";
      if (resp.tappedElement) {
        const el = resp.tappedElement;
        text = `Tapped: ${el.identifier || el.label || "element"}`;
      }
      if (resp.durationMs) text += ` (${resp.durationMs}ms)`;
      return { content: [{ type: "text" as const, text }], details: {} };
    },
  });

  // --- fillField: find text field + type + return screen state ---
  pi.registerTool({
    name: "sim_fill_field",
    label: "Find text field, type text, return screen state",
    description:
      "Find a text field by identifier or label, tap to focus, optionally clear it, type text, and return the resulting screen state.",
    parameters: Type.Object({
      identifier: Type.Optional(
        Type.String({ description: "Text field accessibility identifier" })
      ),
      label: Type.Optional(
        Type.String({ description: "Text field label" })
      ),
      text: Type.String({ description: "Text to type" }),
      clearFirst: Type.Optional(
        Type.Boolean({ description: "Clear existing text first (default: false)" })
      ),
    }),
    async execute(_id, params) {
      const resp = await agentAction("fillField", {
        identifier: params.identifier,
        label: params.label,
        text: params.text,
        clearFirst: params.clearFirst ?? false,
      });

      if (!resp.success) {
        return {
          content: [{ type: "text" as const, text: `Field not found: ${params.identifier || params.label}` }],
          details: {},
          isError: true,
        };
      }

      let fillText = `Typed "${params.text}"`;
      if (resp.durationMs) fillText += ` (${resp.durationMs}ms)`;
      return { content: [{ type: "text" as const, text: fillText }], details: {} };
    },
  });

  // --- observeScreen: get current screen state ---
  pi.registerTool({
    name: "sim_observe",
    label: "Get current screen state",
    description:
      "Return all elements currently visible on screen with their identifiers, labels, types, frames, and enabled state. Use this to see what's on screen without interacting.",
    parameters: Type.Object({}),
    async execute() {
      const resp = await agentAction("observeScreen", {}, true);
      if (!resp.success || !resp.screenState) {
        return {
          content: [
            { type: "text" as const, text: resp.error || "Failed to observe" },
          ],
          details: {},
          isError: true,
        };
      }
      let obsText = formatScreenState(resp.screenState);
      if (resp.durationMs) obsText += `\n(${resp.durationMs}ms)`;
      return {
        content: [
          {
            type: "text" as const,
            text: obsText,
          },
        ],
        details: {},
      };
    },
  });

  // --- longPress: find element + long press ---
  pi.registerTool({
    name: "sim_long_press",
    label: "Long press an element",
    description:
      "Find an element and long-press it (e.g., to open a context menu). Returns the resulting screen state.",
    parameters: Type.Object({
      identifier: Type.Optional(Type.String({ description: "Accessibility identifier" })),
      label: Type.Optional(Type.String({ description: "Exact label text" })),
      labelContains: Type.Optional(Type.String({ description: "Label substring" })),
      duration: Type.Optional(Type.Number({ description: "Press duration in seconds (default: 1)" })),
    }),
    async execute(_id, params) {
      const resp = await agentAction("longPress", {
        identifier: params.identifier,
        label: params.label,
        labelContains: params.labelContains,
        duration: params.duration ?? 1.0,
      });

      if (!resp.success) {
        let text = `Element not found for long press\n`;
        if (resp.screenState) {
          text += `\nElements on screen:\n${formatScreenState(resp.screenState)}`;
        }
        return { content: [{ type: "text" as const, text }], details: {}, isError: true };
      }

      let text = "";
      if (resp.tappedElement) {
        text += `Long pressed: ${formatElement(resp.tappedElement)}\n`;
      }
      if (resp.screenState) {
        text += `\nScreen after long press:\n${formatScreenState(resp.screenState)}`;
      }
      return { content: [{ type: "text" as const, text }], details: {} };
    },
  });

  // --- doubleTap: find element + double tap ---
  pi.registerTool({
    name: "sim_double_tap",
    label: "Double tap an element",
    description:
      "Find an element and double-tap it (e.g., to react to a message). Returns the resulting screen state.",
    parameters: Type.Object({
      identifier: Type.Optional(Type.String({ description: "Accessibility identifier" })),
      label: Type.Optional(Type.String({ description: "Exact label text" })),
      labelContains: Type.Optional(Type.String({ description: "Label substring" })),
    }),
    async execute(_id, params) {
      const resp = await agentAction("doubleTap", {
        identifier: params.identifier,
        label: params.label,
        labelContains: params.labelContains,
      });

      if (!resp.success) {
        let text = `Element not found for double tap\n`;
        if (resp.screenState) {
          text += `\nElements on screen:\n${formatScreenState(resp.screenState)}`;
        }
        return { content: [{ type: "text" as const, text }], details: {}, isError: true };
      }

      let text = "";
      if (resp.tappedElement) {
        text += `Double tapped: ${formatElement(resp.tappedElement)}\n`;
      }
      if (resp.screenState) {
        text += `\nScreen after double tap:\n${formatScreenState(resp.screenState)}`;
      }
      return { content: [{ type: "text" as const, text }], details: {} };
    },
  });

  // --- swipe ---
  pi.registerTool({
    name: "sim_swipe",
    label: "Swipe on screen or element",
    description:
      "Swipe in a direction, optionally on a specific element. Returns the resulting screen state.",
    parameters: Type.Object({
      direction: Type.String({ description: "up, down, left, or right" }),
      identifier: Type.Optional(
        Type.String({ description: "Element to swipe on (swipes app if omitted)" })
      ),
    }),
    async execute(_id, params) {
      const resp = await agentAction("swipe", {
        direction: params.direction,
        identifier: params.identifier,
      });

      if (!resp.success) {
        return {
          content: [{ type: "text" as const, text: resp.error || "Swipe failed" }],
          details: {},
          isError: true,
        };
      }

      let text = `Swiped ${params.direction}`;
      if (resp.screenState) {
        text += `\n\nScreen after swipe:\n${formatScreenState(resp.screenState)}`;
      }
      return { content: [{ type: "text" as const, text }], details: {} };
    },
  });

  // --- scrollUntilVisible ---
  pi.registerTool({
    name: "sim_scroll_to",
    label: "Scroll until element is visible",
    description:
      "Repeatedly swipe until an element matching the query becomes visible and hittable. Returns the element and screen state.",
    parameters: Type.Object({
      identifier: Type.Optional(Type.String({ description: "Accessibility identifier" })),
      label: Type.Optional(Type.String({ description: "Exact label" })),
      labelContains: Type.Optional(Type.String({ description: "Label substring" })),
      direction: Type.Optional(Type.String({ description: "Scroll direction: up or down (default: up)" })),
      maxSwipes: Type.Optional(Type.Number({ description: "Max swipes (default: 10)" })),
    }),
    async execute(_id, params) {
      const resp = await agentAction("scrollUntilVisible", {
        identifier: params.identifier,
        label: params.label,
        labelContains: params.labelContains,
        direction: params.direction ?? "up",
        maxSwipes: params.maxSwipes ?? 10,
      });

      if (!resp.success) {
        let text = `Element not found after scrolling\n`;
        if (resp.screenState) {
          text += `\nElements on screen:\n${formatScreenState(resp.screenState)}`;
        }
        return { content: [{ type: "text" as const, text }], details: {}, isError: true };
      }

      let text = "Found after scrolling";
      if (resp.tappedElement) {
        text += `: ${formatElement(resp.tappedElement)}`;
      }
      if (resp.screenState) {
        text += `\n\nScreen:\n${formatScreenState(resp.screenState)}`;
      }
      return { content: [{ type: "text" as const, text }], details: {} };
    },
  });

  // --- chain: run multiple actions, return final screen state ---
  pi.registerTool({
    name: "sim_chain",
    label: "Run multiple actions in sequence",
    description:
      "Execute a sequence of actions without returning intermediate screen states. Only the final screen state is returned. If any step fails, stops and returns the error with current screen state. Use this to batch predictable sequences like: tap compose → fill field → tap send.",
    parameters: Type.Object({
      steps: Type.Array(
        Type.Object({
          action: Type.String({
            description:
              "Action name: tapElement, fillField, tapCoordinate, swipe, longPress, doubleTap, pressKey, scrollUntilVisible, waitForElement",
          }),
          params: Type.Optional(
            Type.Record(Type.String(), Type.Any(), {
              description: "Action parameters (identifier, label, labelContains, text, etc.)",
            })
          ),
        }),
        { description: "Array of actions to execute in order" }
      ),
    }),
    async execute(_id, params) {
      // chain sends steps at top-level (not wrapped in params)
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 120000);
      let resp: AgentResponse;
      try {
        const r = await fetch(`${AGENT_URL}/action`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "chain", steps: params.steps, observe: true }),
          signal: controller.signal,
        });
        resp = await r.json();
      } finally {
        clearTimeout(timeoutId);
      }

      let text = "";
      if (resp.message) text += resp.message + "\n";
      if (resp.durationMs) text += `Total: ${resp.durationMs}ms\n`;
      if (!resp.success && resp.error) text += `\nError: ${resp.error}\n`;
      if (resp.screenState) {
        text += `\nScreen:\n${formatScreenState(resp.screenState)}`;
      }
      return {
        content: [{ type: "text" as const, text }],
        details: {},
        isError: !resp.success,
      };
    },
  });
}
