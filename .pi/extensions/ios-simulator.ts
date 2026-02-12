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
}
