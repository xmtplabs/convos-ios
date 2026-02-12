import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, existsSync, mkdtempSync, unlinkSync, rmdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const execFileAsync = promisify(execFile);
const IDB_PATH = "/Users/jarod/Library/Python/3.9/bin/idb";

async function getSimulatorUdid(cwd: string): Promise<string> {
  const taskFile = join(cwd, ".convos-task");
  let simName = "";
  if (existsSync(taskFile)) {
    const content = readFileSync(taskFile, "utf-8");
    const match = content.match(/SIMULATOR_NAME=(.+)/);
    if (match) simName = match[1].trim();
  }

  if (!simName) {
    const { stdout } = await execFileAsync("git", ["branch", "--show-current"], { cwd });
    simName = "convos-" + stdout.trim().replace(/[\/\s]+/g, "-").toLowerCase();
  }

  const { stdout } = await execFileAsync("xcrun", [
    "simctl",
    "list",
    "devices",
    "-j",
  ]);
  const devices = JSON.parse(stdout);
  for (const runtime of Object.values(devices.devices) as any[]) {
    for (const dev of runtime) {
      if (dev.name === simName) return dev.udid;
    }
  }
  throw new Error(`Simulator "${simName}" not found`);
}

async function idb(udid: string, ...args: string[]): Promise<{ stdout: string; stderr: string }> {
  const { stdout, stderr } = await execFileAsync(IDB_PATH, args.concat("--udid", udid), {
    maxBuffer: 10 * 1024 * 1024,
  });
  return { stdout: stdout.trim(), stderr: stderr.trim() };
}

export default function (pi: ExtensionAPI) {
  let cachedUdid: string | undefined;

  async function getUdid(cwd: string): Promise<string> {
    if (!cachedUdid) {
      cachedUdid = await getSimulatorUdid(cwd);
    }
    return cachedUdid;
  }

  pi.registerTool({
    name: "sim_screenshot",
    label: "Simulator Screenshot",
    description:
      "Takes a screenshot of the iOS Simulator and returns it as an image. Use this to see the current state of the app.",
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const tmpDir = mkdtempSync(join(tmpdir(), "sim-screenshot-"));
      const screenshotPath = join(tmpDir, "screenshot.png");
      const resizedPath = join(tmpDir, "screenshot-resized.jpeg");
      try {
        await execFileAsync("xcrun", ["simctl", "io", udid, "screenshot", screenshotPath]);
        const maxBase64Bytes = 4.5 * 1024 * 1024;
        let data = readFileSync(screenshotPath);
        let base64 = data.toString("base64");
        let mimeType = "image/png";
        if (base64.length > maxBase64Bytes) {
          try {
            await execFileAsync("sips", ["-Z", "1280", "-s", "format", "jpeg", "-s", "formatOptions", "70", screenshotPath, "--out", resizedPath]);
            data = readFileSync(resizedPath);
            base64 = data.toString("base64");
            mimeType = "image/jpeg";
          } catch {}
        }
        return {
          content: [
            { type: "text" as const, text: `Simulator screenshot [${mimeType}]` },
            { type: "image" as const, data: base64, mimeType },
          ],
          details: {},
        };
      } finally {
        try { unlinkSync(screenshotPath); } catch {}
        try { unlinkSync(resizedPath); } catch {}
        try { rmdirSync(tmpDir); } catch {}
      }
    },
  });

  pi.registerTool({
    name: "sim_tap",
    label: "Simulator Tap",
    description:
      "Tap on a point in the iOS Simulator screen. Coordinates are in points (not pixels). Use sim_describe_ui to find element positions first.",
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in points" }),
      y: Type.Number({ description: "Y coordinate in points" }),
      duration: Type.Optional(
        Type.String({ description: "Press duration in seconds (decimal)" })
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const args = ["ui", "tap"];
      if (params.duration) args.push("--duration", params.duration);
      args.push("--json", String(params.x), String(params.y));
      const { stderr } = await idb(udid, ...args);
      return {
        content: [
          { type: "text", text: `Tapped at (${params.x}, ${params.y})${stderr ? `\n${stderr}` : ""}` },
        ],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_type",
    label: "Simulator Type",
    description: "Input text into the iOS Simulator. The text field must already be focused.",
    parameters: Type.Object({
      text: Type.String({ description: "Text to type (ASCII printable characters only)" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const { stderr } = await idb(udid, "ui", "text", "--json", params.text);
      return {
        content: [
          { type: "text", text: `Typed: "${params.text}"${stderr ? `\n${stderr}` : ""}` },
        ],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_swipe",
    label: "Simulator Swipe",
    description:
      "Swipe on the iOS Simulator screen. Coordinates are in points. Use for scrolling or gesture navigation.",
    parameters: Type.Object({
      x_start: Type.Number({ description: "Starting X coordinate" }),
      y_start: Type.Number({ description: "Starting Y coordinate" }),
      x_end: Type.Number({ description: "Ending X coordinate" }),
      y_end: Type.Number({ description: "Ending Y coordinate" }),
      duration: Type.Optional(
        Type.String({ description: "Swipe duration in seconds (decimal)" })
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const args = ["ui", "swipe"];
      if (params.duration) args.push("--duration", params.duration);
      args.push(
        "--json",
        String(params.x_start),
        String(params.y_start),
        String(params.x_end),
        String(params.y_end)
      );
      const { stderr } = await idb(udid, ...args);
      return {
        content: [
          {
            type: "text",
            text: `Swiped from (${params.x_start}, ${params.y_start}) to (${params.x_end}, ${params.y_end})${stderr ? `\n${stderr}` : ""}`,
          },
        ],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_describe_ui",
    label: "Simulator Describe UI",
    description:
      "Describes all accessibility elements on the current iOS Simulator screen. Returns element labels, roles, frames (in points), and hierarchy. Use this to find tap targets and understand the UI layout.",
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const { stdout } = await idb(udid, "ui", "describe-all", "--json", "--nested");
      try {
        const elements = JSON.parse(stdout);
        const summary = formatAccessibilityTree(elements, 0);
        return {
          content: [{ type: "text", text: summary }],
          details: {},
        };
      } catch {
        return {
          content: [{ type: "text", text: stdout }],
          details: {},
        };
      }
    },
  });

  pi.registerTool({
    name: "sim_describe_point",
    label: "Simulator Describe Point",
    description:
      "Returns the accessibility element at given coordinates on the iOS Simulator screen.",
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in points" }),
      y: Type.Number({ description: "Y coordinate in points" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const { stdout } = await idb(
        udid,
        "ui",
        "describe-point",
        "--json",
        String(params.x),
        String(params.y)
      );
      return {
        content: [{ type: "text", text: stdout }],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_launch_app",
    label: "Simulator Launch App",
    description: "Launches an app on the iOS Simulator by bundle identifier.",
    parameters: Type.Object({
      bundle_id: Type.String({
        description:
          'Bundle identifier (e.g., "org.convos.ios-preview"). Defaults to Convos Dev.',
      }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      const bundleId = params.bundle_id || "org.convos.ios-preview";
      await execFileAsync("xcrun", ["simctl", "launch", udid, bundleId]);
      return {
        content: [{ type: "text", text: `Launched ${bundleId}` }],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_open_url",
    label: "Simulator Open URL",
    description:
      "Opens a URL in the iOS Simulator. Useful for deep links and invite URLs.",
    parameters: Type.Object({
      url: Type.String({ description: "URL to open" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      await execFileAsync("xcrun", ["simctl", "openurl", udid, params.url]);
      return {
        content: [{ type: "text", text: `Opened URL: ${params.url}` }],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "sim_button",
    label: "Simulator Button",
    description:
      "Press a hardware button on the iOS Simulator (e.g., Home button).",
    parameters: Type.Object({
      button: Type.String({
        description:
          'Button name. Use "Home" to go to home screen, or other simctl keyevent names.',
      }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const udid = await getUdid(ctx.cwd);
      try {
        await idb(udid, "ui", "button", "--json", params.button.toUpperCase());
      } catch {
        if (params.button.toLowerCase() === "home") {
          await execFileAsync("xcrun", [
            "simctl",
            "ui",
            udid,
            "appearance",
          ]).catch(() => {});
        }
      }
      return {
        content: [
          { type: "text", text: `Pressed button: ${params.button}` },
        ],
        details: {},
      };
    },
  });
}

function formatAccessibilityTree(elements: any[], depth: number): string {
  const lines: string[] = [];
  const indent = "  ".repeat(depth);

  for (const el of elements) {
    const label = el.AXLabel || el.title || "(no label)";
    const role = el.role_description || el.type || "unknown";
    const frame = el.frame;
    const frameStr = frame
      ? `(${Math.round(frame.x)}, ${Math.round(frame.y)}, ${Math.round(frame.width)}x${Math.round(frame.height)})`
      : "";
    const enabled = el.enabled ? "" : " [disabled]";
    const value = el.AXValue ? ` value="${el.AXValue}"` : "";
    const actions = el.custom_actions?.length
      ? ` actions=[${el.custom_actions.join(", ")}]`
      : "";

    lines.push(
      `${indent}[${role}] "${label}" ${frameStr}${enabled}${value}${actions}`
    );

    if (el.children?.length) {
      lines.push(formatAccessibilityTree(el.children, depth + 1));
    }
  }

  return lines.join("\n");
}
