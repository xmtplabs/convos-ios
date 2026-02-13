import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { execSync } from "node:child_process";

const IDB = "/Users/jarod/Library/Python/3.9/bin/idb";

function getDefaultUdid(): string {
  try {
    const result = execSync(
      `xcrun simctl list devices booted -j 2>/dev/null`,
      { encoding: "utf-8" }
    );
    const json = JSON.parse(result);
    for (const runtime of Object.values(json.devices) as any[]) {
      for (const device of runtime) {
        if (device.state === "Booted") return device.udid;
      }
    }
  } catch {}
  throw new Error("No booted simulator found");
}

interface AccessibilityElement {
  AXUniqueId?: string;
  AXLabel?: string;
  AXFrame?: string;
  frame?: { x: number; y: number; width: number; height: number };
  role?: string;
  type?: string;
  enabled?: boolean;
}

function findElement(
  tree: AccessibilityElement[],
  identifier: string
): AccessibilityElement | null {
  for (const el of tree) {
    if (el.AXUniqueId === identifier) return el;
  }
  for (const el of tree) {
    if (el.AXUniqueId?.startsWith(identifier)) return el;
  }
  for (const el of tree) {
    if (el.AXLabel === identifier) return el;
  }
  for (const el of tree) {
    if (el.AXLabel?.includes(identifier)) return el;
  }
  return null;
}

function matchesIdentifier(el: AccessibilityElement, identifier: string): boolean {
  if (el.AXUniqueId === identifier) return true;
  if (el.AXUniqueId?.startsWith(identifier)) return true;
  if (el.AXLabel === identifier) return true;
  if (el.AXLabel?.includes(identifier)) return true;
  return false;
}

function getAccessibilityTree(udid: string): AccessibilityElement[] {
  const result = execSync(
    `${IDB} ui describe-all --udid ${udid} 2>/dev/null`,
    { encoding: "utf-8" }
  );
  return JSON.parse(result);
}

function describePoint(
  udid: string,
  x: number,
  y: number
): AccessibilityElement | null {
  try {
    const result = execSync(
      `${IDB} ui describe-point ${x} ${y} --udid ${udid} 2>/dev/null`,
      { encoding: "utf-8" }
    );
    return JSON.parse(result);
  } catch {
    return null;
  }
}

function getScreenSize(udid: string): { width: number; height: number } {
  try {
    const result = execSync(
      `xcrun simctl list devices -j 2>/dev/null`,
      { encoding: "utf-8" }
    );
    const json = JSON.parse(result);
    for (const runtime of Object.values(json.devices) as any[]) {
      for (const device of runtime as any[]) {
        if (device.udid === udid && device.logicalSize) {
          return {
            width: device.logicalSize.width,
            height: device.logicalSize.height,
          };
        }
      }
    }
  } catch {}
  return { width: 440, height: 956 };
}

function probeForElement(
  udid: string,
  identifier: string
): AccessibilityElement | null {
  const screen = getScreenSize(udid);
  const probePoints: [number, number][] = [];

  // Bottom toolbar area (most common hidden elements)
  const bottomY = screen.height - 50;
  for (let x = 40; x < screen.width; x += 40) {
    probePoints.push([x, bottomY]);
    probePoints.push([x, bottomY - 20]);
  }

  // Top toolbar area
  const topY = 84;
  for (let x = 40; x < screen.width; x += 40) {
    probePoints.push([x, topY]);
  }

  const seen = new Set<string>();
  for (const [x, y] of probePoints) {
    const el = describePoint(udid, x, y);
    if (!el) continue;
    const key = `${el.AXUniqueId || ""}:${el.AXLabel || ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (matchesIdentifier(el, identifier)) return el;
  }
  return null;
}

function tapPoint(udid: string, x: number, y: number) {
  execSync(`${IDB} ui tap ${x} ${y} --udid ${udid} 2>/dev/null`);
}

function getCenter(el: AccessibilityElement): { x: number; y: number } {
  if (el.frame) {
    return {
      x: el.frame.x + el.frame.width / 2,
      y: el.frame.y + el.frame.height / 2,
    };
  }
  if (el.AXFrame) {
    const match = el.AXFrame.match(
      /\{\{([\d.]+),\s*([\d.]+)\},\s*\{([\d.]+),\s*([\d.]+)\}\}/
    );
    if (match) {
      return {
        x: parseFloat(match[1]) + parseFloat(match[3]) / 2,
        y: parseFloat(match[2]) + parseFloat(match[4]) / 2,
      };
    }
  }
  throw new Error("Cannot determine element center");
}

function tryFindAndTap(
  udid: string,
  identifier: string
): { found: boolean; message: string } {
  // 1. Try tree search first (fast)
  const tree = getAccessibilityTree(udid);
  const el = findElement(tree, identifier);
  if (el) {
    const center = getCenter(el);
    tapPoint(udid, Math.round(center.x), Math.round(center.y));
    return {
      found: true,
      message: `id=${el.AXUniqueId || "none"}, label="${el.AXLabel || ""}", center=(${Math.round(center.x)},${Math.round(center.y)})`,
    };
  }

  // 2. Probe toolbar areas for hidden elements
  const probed = probeForElement(udid, identifier);
  if (probed) {
    const center = getCenter(probed);
    tapPoint(udid, Math.round(center.x), Math.round(center.y));
    return {
      found: true,
      message: `id=${probed.AXUniqueId || "none"}, label="${probed.AXLabel || ""}", center=(${Math.round(center.x)},${Math.round(center.y)}) [found via probe]`,
    };
  }

  return { found: false, message: "" };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "sim_wait_and_tap",
    label: "Wait for element then tap it",
    description:
      "Poll the accessibility tree until an element with the given identifier or label appears, then immediately tap it. Combines sim_wait_for_element + sim_tap_id into a single call. Also probes toolbar areas for elements hidden from tree traversal. Returns the element info that was tapped.",
    parameters: Type.Object({
      identifier: Type.String({
        description: "Accessibility identifier or label to wait for and tap",
      }),
      timeout: Type.Optional(
        Type.Number({
          description: "Maximum wait time in seconds (default: 5)",
        })
      ),
      udid: Type.Optional(
        Type.String({
          description: "Simulator UDID. Auto-detected if omitted.",
        })
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = params.udid || getDefaultUdid();
      const timeout = params.timeout ?? 5;
      const interval = 0.5;
      const maxAttempts = Math.ceil(timeout / interval);
      const startTime = Date.now();

      for (let i = 0; i < maxAttempts; i++) {
        if (signal?.aborted) throw new Error("Aborted");

        try {
          const result = tryFindAndTap(udid, params.identifier);
          if (result.found) {
            const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Found and tapped after ${elapsed}s: ${result.message}`,
                },
              ],
              details: {},
            };
          }
        } catch (e: any) {
          if (e.message === "Aborted") throw e;
        }

        await new Promise((r) => setTimeout(r, interval * 1000));
      }

      let available = "";
      try {
        const tree = getAccessibilityTree(udid);
        available = tree
          .filter((e: any) => e.AXUniqueId || e.AXLabel)
          .map(
            (e: any) =>
              `  ${e.AXUniqueId || "(no id)"}: "${e.AXLabel || ""}" [${e.role || ""}]`
          )
          .join("\n");
      } catch {}

      return {
        content: [
          {
            type: "text" as const,
            text: `Timed out after ${timeout}s waiting for "${params.identifier}"\n\nAvailable elements:\n${available}`,
          },
        ],
        details: {},
        isError: true,
      };
    },
  });
}
