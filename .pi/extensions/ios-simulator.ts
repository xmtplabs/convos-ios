import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

let cachedIdbPath: string | undefined;

function findIdb(): string {
  if (cachedIdbPath) return cachedIdbPath;

  const { execSync } = require("node:child_process");

  // 1. Check IDB_PATH env var
  if (process.env.IDB_PATH) {
    cachedIdbPath = process.env.IDB_PATH;
    return cachedIdbPath;
  }

  // 2. Check if idb is in PATH
  try {
    const result = execSync("which idb", { encoding: "utf-8", timeout: 3000 }).trim();
    if (result) {
      cachedIdbPath = result;
      return cachedIdbPath;
    }
  } catch {}

  // 3. Check common pip user install locations
  try {
    const userBin = execSync(
      `python3 -c "import site; print(site.getusersitepackages().replace('/lib/python/site-packages', '/bin/idb'))"`,
      { encoding: "utf-8", timeout: 3000 }
    ).trim();
    if (fs.existsSync(userBin)) {
      cachedIdbPath = userBin;
      return cachedIdbPath;
    }
  } catch {}

  // 4. Check Homebrew pip locations
  for (const pyVer of ["3.9", "3.10", "3.11", "3.12", "3.13"]) {
    const candidate = path.join(os.homedir(), `Library/Python/${pyVer}/bin/idb`);
    if (fs.existsSync(candidate)) {
      cachedIdbPath = candidate;
      return cachedIdbPath;
    }
  }

  throw new Error(
    "idb not found. Install it with: pip3 install fb-idb\n" +
    "Or set the IDB_PATH environment variable to the idb binary path."
  );
}

function getSimulatorId(): string | undefined {
  const taskFile = path.join(process.cwd(), ".convos-task");
  let simName: string | undefined;

  if (fs.existsSync(taskFile)) {
    const content = fs.readFileSync(taskFile, "utf-8");
    const match = content.match(/SIMULATOR_NAME=(.+)/);
    simName = match?.[1]?.trim();
  }

  if (!simName) {
    const idFile = path.join(process.cwd(), ".claude", ".simulator_id");
    if (fs.existsSync(idFile)) {
      return fs.readFileSync(idFile, "utf-8").trim();
    }
  }

  return undefined;
}

async function resolveUdid(pi: ExtensionAPI, explicitUdid?: string): Promise<string> {
  if (explicitUdid) return explicitUdid;

  const simIdFile = path.join(process.cwd(), ".claude", ".simulator_id");
  if (fs.existsSync(simIdFile)) {
    return fs.readFileSync(simIdFile, "utf-8").trim();
  }

  const result = await pi.exec("xcrun", ["simctl", "list", "devices", "booted", "-j"], { timeout: 5000 });
  if (result.code === 0) {
    const data = JSON.parse(result.stdout);
    for (const runtime of Object.values(data.devices) as any[]) {
      for (const dev of runtime) {
        if (dev.state === "Booted") return dev.udid;
      }
    }
  }

  throw new Error("No booted simulator found. Boot one first with: xcrun simctl boot <name>");
}

// --- Log file helpers ---

function findAppLogFile(udid: string): string | null {
  const { execSync } = require("node:child_process");
  try {
    const result = execSync(
      `find ~/Library/Developer/CoreSimulator/Devices/${udid}/data/Containers/Shared/AppGroup -name "convos.log" 2>/dev/null | head -1`,
      { encoding: "utf-8", timeout: 5000 }
    ).trim();
    return result || null;
  } catch {
    return null;
  }
}

// --- Shared helpers ---

interface AXElement {
  AXUniqueId: string | null;
  AXLabel: string | null;
  AXValue: string | null;
  type: string;
  role: string;
  frame: { x: number; y: number; width: number; height: number };
  enabled: boolean;
  custom_actions?: string[];
}

async function getAccessibilityTree(pi: ExtensionAPI, idbPath: string, udid: string, signal?: AbortSignal): Promise<AXElement[]> {
  const result = await pi.exec(idbPath, ["ui", "describe-all", "--udid", udid, "--json"], {
    signal,
    timeout: 10000,
  });
  if (result.code !== 0) {
    throw new Error(`Failed to get accessibility tree: ${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
}

function findElement(elements: AXElement[], identifier: string): AXElement | undefined {
  // 1. Exact match on AXUniqueId (accessibility identifier)
  let match = elements.find(el => el.AXUniqueId === identifier);
  if (match) return match;

  // 2. Prefix match on AXUniqueId (e.g. "conversation-list-item-" matches dynamic ids)
  match = elements.find(el => el.AXUniqueId?.startsWith(identifier) ?? false);
  if (match) return match;

  // 3. Exact match on AXLabel
  match = elements.find(el => el.AXLabel === identifier);
  if (match) return match;

  // 4. Case-insensitive substring match on AXLabel
  const lowerIdentifier = identifier.toLowerCase();
  match = elements.find(el => el.AXLabel?.toLowerCase().includes(lowerIdentifier) ?? false);
  if (match) return match;

  return undefined;
}

function elementCenter(el: AXElement): { x: number; y: number } {
  return {
    x: Math.round(el.frame.x + el.frame.width / 2),
    y: Math.round(el.frame.y + el.frame.height / 2),
  };
}

function formatElementInfo(el: AXElement): string {
  const center = elementCenter(el);
  return `id=${el.AXUniqueId || "none"}, label="${el.AXLabel || ""}", type=${el.type}, center=(${center.x},${center.y}), enabled=${el.enabled}`;
}

export default function (pi: ExtensionAPI) {
  // --- ui_describe_all: Get full accessibility tree ---
  pi.registerTool({
    name: "sim_ui_describe_all",
    label: "Simulator: Describe All UI",
    description:
      "Returns the full accessibility tree of the iOS Simulator screen as JSON. Each element includes AXLabel, AXUniqueId (accessibility identifier), AXValue, AXFrame (coordinates), role, type, enabled state, and custom_actions. Use this to find elements for tapping, verify accessibility labels, or understand the screen layout.",
    parameters: Type.Object({
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const result = await pi.exec(findIdb(), ["ui", "describe-all", "--udid", udid, "--json"], {
        signal,
        timeout: 10000,
      });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      try {
        const elements = JSON.parse(result.stdout);
        const summary = elements.map((el: any) => ({
          id: el.AXUniqueId || null,
          label: el.AXLabel || null,
          value: el.AXValue || null,
          type: el.type,
          role: el.role,
          frame: el.frame,
          enabled: el.enabled,
          actions: el.custom_actions?.length ? el.custom_actions : undefined,
        }));
        return { content: [{ type: "text", text: JSON.stringify(summary, null, 2) }], details: {} };
      } catch {
        return { content: [{ type: "text", text: result.stdout }], details: {} };
      }
    },
  });

  // --- ui_tap: Tap on the screen ---
  pi.registerTool({
    name: "sim_ui_tap",
    label: "Simulator: Tap",
    description:
      "Tap at specific coordinates (in points, not pixels) on the iOS Simulator screen. Use sim_ui_describe_all first to find element coordinates from their frame property.",
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in points" }),
      y: Type.Number({ description: "Y coordinate in points" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
      duration: Type.Optional(Type.Number({ description: "Press duration in seconds for long press" })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const args = ["ui", "tap", "--udid", udid, String(params.x), String(params.y)];
      if (params.duration) args.push("--duration", String(params.duration));
      const result = await pi.exec(findIdb(), args, { signal, timeout: 10000 });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: `Tapped at (${params.x}, ${params.y})` }], details: {} };
    },
  });

  // --- ui_swipe: Swipe on the screen ---
  pi.registerTool({
    name: "sim_ui_swipe",
    label: "Simulator: Swipe",
    description:
      "Swipe from one point to another on the iOS Simulator screen. Coordinates are in points.",
    parameters: Type.Object({
      x_start: Type.Number({ description: "Starting X coordinate" }),
      y_start: Type.Number({ description: "Starting Y coordinate" }),
      x_end: Type.Number({ description: "Ending X coordinate" }),
      y_end: Type.Number({ description: "Ending Y coordinate" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
      duration: Type.Optional(Type.Number({ description: "Swipe duration in seconds" })),
      delta: Type.Optional(Type.Number({ description: "Step size (default 1)" })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const args = [
        "ui",
        "swipe",
        "--udid",
        udid,
        String(params.x_start),
        String(params.y_start),
        String(params.x_end),
        String(params.y_end),
      ];
      if (params.duration) args.push("--duration", String(params.duration));
      if (params.delta) args.push("--delta", String(params.delta));
      const result = await pi.exec(findIdb(), args, { signal, timeout: 10000 });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return {
        content: [
          {
            type: "text",
            text: `Swiped from (${params.x_start}, ${params.y_start}) to (${params.x_end}, ${params.y_end})`,
          },
        ],
        details: {},
      };
    },
  });

  // --- ui_type: Type text ---
  pi.registerTool({
    name: "sim_ui_type",
    label: "Simulator: Type Text",
    description:
      "Type text into the currently focused field in the iOS Simulator. Tap a text field first to focus it.",
    parameters: Type.Object({
      text: Type.String({ description: "Text to type" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const result = await pi.exec(findIdb(), ["ui", "text", "--udid", udid, params.text], {
        signal,
        timeout: 10000,
      });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: `Typed: "${params.text}"` }], details: {} };
    },
  });

  // --- ui_key: Press a key ---
  pi.registerTool({
    name: "sim_ui_key",
    label: "Simulator: Press Key",
    description:
      "Press a key event in the iOS Simulator. Common key codes: 40 = Return/Enter, 42 = Backspace/Delete, 41 = Escape.",
    parameters: Type.Object({
      keycode: Type.Number({ description: "HID key code to press (e.g. 40 for Return)" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const result = await pi.exec(findIdb(), ["ui", "key", "--udid", udid, String(params.keycode)], {
        signal,
        timeout: 10000,
      });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: `Pressed key code: ${params.keycode}` }], details: {} };
    },
  });

  // --- screenshot: Take a screenshot and return as image ---
  pi.registerTool({
    name: "sim_screenshot",
    label: "Simulator: Screenshot",
    description:
      "Take a screenshot of the iOS Simulator and return it as an image. Use this to see the current state of the app.",
    parameters: Type.Object({
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const tmpFile = path.join(os.tmpdir(), `sim-screenshot-${Date.now()}.png`);
      const resizedFile = tmpFile.replace(".png", "-resized.jpeg");
      try {
        const result = await pi.exec("xcrun", ["simctl", "io", udid, "screenshot", tmpFile], {
          signal,
          timeout: 10000,
        });
        if (result.code !== 0) {
          return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
        }
        // Always resize to fit within 1400px max dimension and convert to JPEG.
        // This satisfies both the 2000px per-dimension API limit for many-image
        // requests and keeps file sizes small.
        await pi.exec("sips", ["-Z", "1400", "-s", "format", "jpeg", "-s", "formatOptions", "70", tmpFile, "--out", resizedFile], {
          signal,
          timeout: 10000,
        });
        let imageData: Buffer;
        let mimeType: string;
        if (fs.existsSync(resizedFile)) {
          imageData = fs.readFileSync(resizedFile);
          mimeType = "image/jpeg";
        } else {
          // Fallback to original if resize somehow failed
          imageData = fs.readFileSync(tmpFile);
          mimeType = "image/png";
        }
        const base64 = imageData.toString("base64");
        return {
          content: [
            { type: "image", data: base64, mimeType },
            { type: "text", text: `Screenshot taken (${udid})` },
          ],
          details: {},
        };
      } finally {
        try { fs.unlinkSync(tmpFile); } catch {}
        try { fs.unlinkSync(resizedFile); } catch {}
      }
    },
  });

  // --- ui_describe_point: Describe element at point ---
  pi.registerTool({
    name: "sim_ui_describe_point",
    label: "Simulator: Describe Point",
    description:
      "Returns accessibility information for the element at specific coordinates in the iOS Simulator.",
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in points" }),
      y: Type.Number({ description: "Y coordinate in points" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const result = await pi.exec(
        findIdb(),
        ["ui", "describe-point", "--udid", udid, "--json", String(params.x), String(params.y)],
        { signal, timeout: 10000 }
      );
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: result.stdout }], details: {} };
    },
  });

  // --- open_url: Open a URL in the simulator ---
  pi.registerTool({
    name: "sim_open_url",
    label: "Simulator: Open URL",
    description:
      "Open a URL in the iOS Simulator (deep links, universal links, web URLs).",
    parameters: Type.Object({
      url: Type.String({ description: "URL to open" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const result = await pi.exec("xcrun", ["simctl", "openurl", udid, params.url], {
        signal,
        timeout: 10000,
      });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: `Opened URL: ${params.url}` }], details: {} };
    },
  });

  // --- launch_app: Launch an app ---
  pi.registerTool({
    name: "sim_launch_app",
    label: "Simulator: Launch App",
    description: "Launch an app on the iOS Simulator by bundle identifier.",
    parameters: Type.Object({
      bundle_id: Type.String({ description: "Bundle identifier (e.g. org.convos.ios-preview)" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
      terminate_first: Type.Optional(
        Type.Boolean({ description: "Terminate the app first if running (default: false)" })
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      if (params.terminate_first) {
        await pi.exec("xcrun", ["simctl", "terminate", udid, params.bundle_id], { signal, timeout: 5000 });
      }
      const result = await pi.exec("xcrun", ["simctl", "launch", udid, params.bundle_id], {
        signal,
        timeout: 10000,
      });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Error: ${result.stderr || result.stdout}` }], isError: true };
      }
      return { content: [{ type: "text", text: `Launched ${params.bundle_id}` }], details: {} };
    },
  });

  // --- tap_id: Tap an element by accessibility identifier or label ---
  pi.registerTool({
    name: "sim_tap_id",
    label: "Simulator: Tap Element by ID",
    description:
      "Find a UI element by its accessibility identifier or label and tap it. " +
      "Searches in order: exact accessibilityIdentifier match, prefix match on identifier, " +
      "exact label match, then substring label match. " +
      "Returns the element info that was tapped, or an error if not found. " +
      "This is faster and more reliable than calling describe_all + tap separately.",
    parameters: Type.Object({
      identifier: Type.String({ description: "Accessibility identifier, label text, or substring to search for" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
      duration: Type.Optional(Type.Number({ description: "Press duration in seconds for long press" })),
      retries: Type.Optional(Type.Number({ description: "Number of retries if element not found (default 0). Waits 1s between retries." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const idbPath = findIdb();
      const maxAttempts = (params.retries ?? 0) + 1;

      for (let attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) {
          await new Promise(resolve => setTimeout(resolve, 1000));
        }

        let elements: AXElement[];
        try {
          elements = await getAccessibilityTree(pi, idbPath, udid, signal);
        } catch (e: any) {
          return { content: [{ type: "text", text: `Error getting accessibility tree: ${e.message}` }], isError: true };
        }

        const el = findElement(elements, params.identifier);
        if (!el) {
          if (attempt < maxAttempts - 1) continue;
          const available = elements
            .filter(e => e.AXUniqueId || e.AXLabel)
            .map(e => `  ${e.AXUniqueId || "(no id)"}: "${e.AXLabel || ""}" [${e.type}]`)
            .join("\n");
          return {
            content: [{ type: "text", text: `Element not found: "${params.identifier}"\n\nAvailable elements:\n${available}` }],
            isError: true,
          };
        }

        if (!el.enabled) {
          return {
            content: [{ type: "text", text: `Element found but disabled: ${formatElementInfo(el)}` }],
            isError: true,
          };
        }

        const center = elementCenter(el);
        const args = ["ui", "tap", "--udid", udid, String(center.x), String(center.y)];
        if (params.duration) args.push("--duration", String(params.duration));
        const tapResult = await pi.exec(idbPath, args, { signal, timeout: 10000 });
        if (tapResult.code !== 0) {
          return { content: [{ type: "text", text: `Tap failed: ${tapResult.stderr || tapResult.stdout}` }], isError: true };
        }

        return {
          content: [{ type: "text", text: `Tapped: ${formatElementInfo(el)}` }],
          details: {},
        };
      }

      return { content: [{ type: "text", text: `Element not found after ${maxAttempts} attempts: "${params.identifier}"` }], isError: true };
    },
  });

  // --- type_in_field: Tap a text field by id and type text into it ---
  pi.registerTool({
    name: "sim_type_in_field",
    label: "Simulator: Type in Field by ID",
    description:
      "Find a text field by accessibility identifier or label, tap to focus it, then type text. " +
      "Combines field lookup, tap-to-focus, and text input into a single operation. " +
      "Optionally clears the field first. Much more reliable than separate tap + type calls.",
    parameters: Type.Object({
      identifier: Type.String({ description: "Accessibility identifier or label of the text field" }),
      text: Type.String({ description: "Text to type into the field" }),
      clear_first: Type.Optional(Type.Boolean({ description: "Select all and delete existing text before typing (default: false)" })),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const idbPath = findIdb();

      let elements: AXElement[];
      try {
        elements = await getAccessibilityTree(pi, idbPath, udid, signal);
      } catch (e: any) {
        return { content: [{ type: "text", text: `Error getting accessibility tree: ${e.message}` }], isError: true };
      }

      const el = findElement(elements, params.identifier);
      if (!el) {
        return {
          content: [{ type: "text", text: `Text field not found: "${params.identifier}"` }],
          isError: true,
        };
      }

      // Tap to focus the field
      const center = elementCenter(el);
      const tapResult = await pi.exec(idbPath, ["ui", "tap", "--udid", udid, String(center.x), String(center.y)], {
        signal,
        timeout: 10000,
      });
      if (tapResult.code !== 0) {
        return { content: [{ type: "text", text: `Failed to tap field: ${tapResult.stderr || tapResult.stdout}` }], isError: true };
      }

      // Brief pause for focus to register
      await new Promise(resolve => setTimeout(resolve, 300));

      // Clear existing text if requested
      if (params.clear_first) {
        // Select all (Cmd+A) then delete
        // HID key codes: Cmd modifier isn't directly supported by idb key, 
        // so we use a different approach: triple-tap to select all, then backspace
        await pi.exec(idbPath, ["ui", "tap", "--udid", udid, String(center.x), String(center.y)], { signal, timeout: 5000 });
        await new Promise(resolve => setTimeout(resolve, 100));
        await pi.exec(idbPath, ["ui", "tap", "--udid", udid, String(center.x), String(center.y)], { signal, timeout: 5000 });
        await new Promise(resolve => setTimeout(resolve, 100));
        await pi.exec(idbPath, ["ui", "tap", "--udid", udid, String(center.x), String(center.y)], { signal, timeout: 5000 });
        await new Promise(resolve => setTimeout(resolve, 200));
        // Delete selected text
        await pi.exec(idbPath, ["ui", "key", "--udid", udid, "42"], { signal, timeout: 5000 });
        await new Promise(resolve => setTimeout(resolve, 200));
      }

      // Type the text
      const typeResult = await pi.exec(idbPath, ["ui", "text", "--udid", udid, params.text], {
        signal,
        timeout: 10000,
      });
      if (typeResult.code !== 0) {
        return { content: [{ type: "text", text: `Failed to type text: ${typeResult.stderr || typeResult.stdout}` }], isError: true };
      }

      return {
        content: [{ type: "text", text: `Typed "${params.text}" into ${formatElementInfo(el)}` }],
        details: {},
      };
    },
  });

  // --- wait_for_element: Wait for an element to appear ---
  pi.registerTool({
    name: "sim_wait_for_element",
    label: "Simulator: Wait for Element",
    description:
      "Poll the accessibility tree until an element with the given identifier or label appears. " +
      "Useful for waiting after navigation, network requests, or animations. " +
      "Returns the element info when found, or an error after timeout.",
    parameters: Type.Object({
      identifier: Type.String({ description: "Accessibility identifier or label to wait for" }),
      timeout: Type.Optional(Type.Number({ description: "Maximum wait time in seconds (default: 10)" })),
      interval: Type.Optional(Type.Number({ description: "Poll interval in seconds (default: 1)" })),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const idbPath = findIdb();
      const timeoutMs = (params.timeout ?? 10) * 1000;
      const intervalMs = (params.interval ?? 1) * 1000;
      const start = Date.now();

      while (Date.now() - start < timeoutMs) {
        let elements: AXElement[];
        try {
          elements = await getAccessibilityTree(pi, idbPath, udid, signal);
        } catch {
          await new Promise(resolve => setTimeout(resolve, intervalMs));
          continue;
        }

        const el = findElement(elements, params.identifier);
        if (el) {
          const elapsed = ((Date.now() - start) / 1000).toFixed(1);
          return {
            content: [{ type: "text", text: `Found after ${elapsed}s: ${formatElementInfo(el)}` }],
            details: {},
          };
        }

        await new Promise(resolve => setTimeout(resolve, intervalMs));
      }

      // Final attempt — return available elements for debugging
      try {
        const elements = await getAccessibilityTree(pi, idbPath, udid, signal);
        const available = elements
          .filter(e => e.AXUniqueId || e.AXLabel)
          .map(e => `  ${e.AXUniqueId || "(no id)"}: "${e.AXLabel || ""}" [${e.type}]`)
          .join("\n");
        return {
          content: [{ type: "text", text: `Timed out after ${params.timeout ?? 10}s waiting for "${params.identifier}"\n\nAvailable elements:\n${available}` }],
          isError: true,
        };
      } catch {
        return {
          content: [{ type: "text", text: `Timed out after ${params.timeout ?? 10}s waiting for "${params.identifier}"` }],
          isError: true,
        };
      }
    },
  });

  // --- log_tail: Read recent app logs, filtered by level ---
  pi.registerTool({
    name: "sim_log_tail",
    label: "Simulator: Tail App Logs",
    description:
      "Read recent lines from the Convos app log file on the simulator. " +
      "By default filters for warning and error level logs only. " +
      "Reads from the end of the log file. Use `since_marker` to only get logs newer than a previously returned marker.",
    parameters: Type.Object({
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
      lines: Type.Optional(Type.Number({ description: "Maximum number of lines to return (default: 100)" })),
      level: Type.Optional(Type.String({ description: "Filter level: 'all', 'warning+error' (default), 'error'" })),
      since_marker: Type.Optional(Type.String({ description: "Only return logs after this timestamp marker (ISO8601 from a previous call)" })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const logFile = findAppLogFile(udid);
      if (!logFile) {
        return { content: [{ type: "text", text: "No log file found for this simulator. The app may not have been launched yet." }], details: {} };
      }

      const maxLines = params.lines ?? 100;
      const level = params.level ?? "warning+error";

      // Read the tail of the log file
      const result = await pi.exec("tail", ["-n", String(maxLines * 5), logFile], { signal, timeout: 5000 });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Failed to read log file: ${result.stderr}` }], isError: true };
      }

      let lines = result.stdout.split("\n").filter(l => l.trim().length > 0);

      // Filter by level
      if (level === "warning+error") {
        lines = lines.filter(l => l.includes("[warning]") || l.includes("[error]"));
      } else if (level === "error") {
        lines = lines.filter(l => l.includes("[error]"));
      }

      // Filter by since_marker (timestamp comparison)
      if (params.since_marker) {
        const markerTime = params.since_marker;
        lines = lines.filter(l => {
          const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T[\d:]+Z)\]/);
          if (!match) return false;
          return match[1] > markerTime;
        });
      }

      // Trim to maxLines
      lines = lines.slice(-maxLines);

      if (lines.length === 0) {
        const marker = new Date().toISOString().replace(/\.\d{3}/, "");
        return {
          content: [{ type: "text", text: `No ${level === "all" ? "" : level + " "}logs found.\nmarker: ${marker}` }],
          details: {},
        };
      }

      // Extract latest timestamp as marker for next call
      const lastLine = lines[lines.length - 1];
      const tsMatch = lastLine.match(/^\[(\d{4}-\d{2}-\d{2}T[\d:]+Z)\]/);
      const marker = tsMatch ? tsMatch[1] : new Date().toISOString().replace(/\.\d{3}/, "");

      return {
        content: [{ type: "text", text: `${lines.length} log entries (${level}):\n\n${lines.join("\n")}\n\nmarker: ${marker}` }],
        details: {},
      };
    },
  });

  // --- log_check_errors: Quick check for new errors since a marker ---
  pi.registerTool({
    name: "sim_log_check_errors",
    label: "Simulator: Check for Log Errors",
    description:
      "Quick check for new error-level log entries since a given marker timestamp. " +
      "Returns errors if any, or confirms no errors. " +
      "Use this between test steps to detect app errors early. " +
      "Call sim_log_tail first to get an initial marker, then pass that marker here.",
    parameters: Type.Object({
      since_marker: Type.String({ description: "Timestamp marker from a previous sim_log_tail or sim_log_check_errors call" }),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const logFile = findAppLogFile(udid);
      if (!logFile) {
        return { content: [{ type: "text", text: "No log file found." }], details: {} };
      }

      // Read recent logs
      const result = await pi.exec("tail", ["-n", "500", logFile], { signal, timeout: 5000 });
      if (result.code !== 0) {
        return { content: [{ type: "text", text: `Failed to read log file: ${result.stderr}` }], isError: true };
      }

      const markerTime = params.since_marker;
      const errors = result.stdout.split("\n")
        .filter(l => l.includes("[error]"))
        .filter(l => {
          const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T[\d:]+Z)\]/);
          if (!match) return false;
          return match[1] > markerTime;
        });

      const warnings = result.stdout.split("\n")
        .filter(l => l.includes("[warning]"))
        .filter(l => {
          const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T[\d:]+Z)\]/);
          if (!match) return false;
          return match[1] > markerTime;
        });

      // New marker
      const allNew = [...warnings, ...errors];
      let newMarker = markerTime;
      if (allNew.length > 0) {
        const lastLine = allNew[allNew.length - 1];
        const tsMatch = lastLine.match(/^\[(\d{4}-\d{2}-\d{2}T[\d:]+Z)\]/);
        if (tsMatch) newMarker = tsMatch[1];
      } else {
        newMarker = new Date().toISOString().replace(/\.\d{3}/, "");
      }

      if (errors.length > 0) {
        return {
          content: [{
            type: "text",
            text: `⚠️ ${errors.length} ERROR(s) detected since ${markerTime}:\n\n${errors.join("\n")}${warnings.length > 0 ? `\n\n${warnings.length} warning(s):\n${warnings.join("\n")}` : ""}\n\nmarker: ${newMarker}`,
          }],
          isError: true,
        };
      }

      if (warnings.length > 0) {
        return {
          content: [{
            type: "text",
            text: `No errors. ${warnings.length} warning(s) since ${markerTime}:\n\n${warnings.join("\n")}\n\nmarker: ${newMarker}`,
          }],
          details: {},
        };
      }

      return {
        content: [{ type: "text", text: `✅ No errors or warnings since ${markerTime}\nmarker: ${newMarker}` }],
        details: {},
      };
    },
  });

  // --- find_elements: Search for elements matching a pattern ---
  pi.registerTool({
    name: "sim_find_elements",
    label: "Simulator: Find Elements",
    description:
      "Search the accessibility tree for elements matching a pattern. " +
      "Returns all matches with their identifiers, labels, types, frames, and enabled state. " +
      "Useful for checking what's on screen, finding dynamic element IDs, or verifying content.",
    parameters: Type.Object({
      pattern: Type.Optional(Type.String({ description: "Search pattern (substring match on id or label). Omit to list all elements with identifiers." })),
      udid: Type.Optional(Type.String({ description: "Simulator UDID. Auto-detected if omitted." })),
    }),
    async execute(_toolCallId, params, signal) {
      const udid = await resolveUdid(pi, params.udid);
      const idbPath = findIdb();

      let elements: AXElement[];
      try {
        elements = await getAccessibilityTree(pi, idbPath, udid, signal);
      } catch (e: any) {
        return { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true };
      }

      let matches: AXElement[];
      if (params.pattern) {
        const lowerPattern = params.pattern.toLowerCase();
        matches = elements.filter(el =>
          (el.AXUniqueId?.toLowerCase().includes(lowerPattern) ?? false) ||
          (el.AXLabel?.toLowerCase().includes(lowerPattern) ?? false) ||
          (el.AXValue?.toLowerCase().includes(lowerPattern) ?? false)
        );
      } else {
        matches = elements.filter(el => el.AXUniqueId || el.AXLabel);
      }

      if (matches.length === 0) {
        return { content: [{ type: "text", text: `No elements found${params.pattern ? ` matching "${params.pattern}"` : ""}` }], details: {} };
      }

      const summary = matches.map(el => ({
        id: el.AXUniqueId || null,
        label: el.AXLabel || null,
        value: el.AXValue || null,
        type: el.type,
        enabled: el.enabled,
        center: elementCenter(el),
        actions: el.custom_actions?.length ? el.custom_actions : undefined,
      }));

      return { content: [{ type: "text", text: JSON.stringify(summary, null, 2) }], details: {} };
    },
  });
}
