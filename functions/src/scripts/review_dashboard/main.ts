/*
 * main.ts — local review dashboard for postbox problem reports.
 *
 * A desktop-first replacement for the app's "Admin · Reports" screen: a
 * keyboard-driven queue with a map, photo EXIF checks, duplicate flags,
 * reporter context, a rescore impact preview, and a batch .osc builder for
 * OSM follow-up. Accept/reject runs performReview, the same code as the
 * reviewReport callable, against PRODUCTION through the Admin SDK.
 *
 * Run (from functions/, after building the frontend once in admin_dashboard/):
 *
 *   npm run review-dashboard -- --reviewer <uid|email> [options]
 *
 * Options:
 *   --reviewer <uid|email>  Admin account recorded as reviewedBy (required;
 *                           must hold the `admin` custom claim)
 *   --port <n>              Port on 127.0.0.1 (default 8790)
 *   --project <id>          Firebase project (default the-postbox-game)
 *   --dev                   Frontend served by Vite (admin_dashboard: npm run dev);
 *                           REVIEW_DASHBOARD_TOKEN (32+ chars) pins the token
 *   --dev-port <n>          Vite port for --dev (default 5173)
 *   --static <dir>          Built frontend (default ../admin_dashboard/dist)
 *   --open                  Open the dashboard in the default browser
 *   --ignore-maintenance    Allow reviews while Remote Config maintenance_mode is on
 *   --help
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON, or
 * `gcloud auth application-default login` (+ set-quota-project). Startup
 * refuses to run unless Auth, Remote Config and Storage are all reachable:
 * scoring must never fall back to hard-coded points silently.
 */

import { spawn } from "child_process";
import { randomBytes } from "crypto";
import * as path from "path";
import { MIN_TOKEN_LENGTH } from "./_security";

export interface DashboardArgs {
  reviewer: string | null;
  port: number;
  projectId: string;
  dev: boolean;
  devPort: number;
  staticDir: string;
  open: boolean;
  ignoreMaintenance: boolean;
  help: boolean;
}

const USAGE = `Usage: npm run review-dashboard -- --reviewer <uid|email> [--port 8790] [--project the-postbox-game]
       [--dev [--dev-port 5173]] [--static <dir>] [--open] [--ignore-maintenance]`;

function parsePort(raw: string | undefined, flag: string): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) throw new Error(`${flag} needs a port number (1-65535)`);
  return n;
}

/** Parses argv (already sliced past `node main.js`). Throws on bad input. */
export function parseDashboardArgs(argv: ReadonlyArray<string>): DashboardArgs {
  const opts: DashboardArgs = {
    reviewer: null,
    port: 8790,
    projectId: "the-postbox-game",
    dev: false,
    devPort: 5173,
    staticDir: path.resolve(__dirname, "../../../../admin_dashboard/dist"),
    open: false,
    ignoreMaintenance: false,
    help: false,
  };
  const value = (i: number, flag: string): string => {
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`${flag} needs a value`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--reviewer": opts.reviewer = value(i++, a); break;
      case "--port": opts.port = parsePort(value(i++, a), a); break;
      case "--project": opts.projectId = value(i++, a); break;
      case "--dev": opts.dev = true; break;
      case "--dev-port": opts.devPort = parsePort(value(i++, a), a); break;
      case "--static": opts.staticDir = path.resolve(value(i++, a)); break;
      case "--open": opts.open = true; break;
      case "--ignore-maintenance": opts.ignoreMaintenance = true; break;
      case "--help": case "-h": opts.help = true; break;
      default: throw new Error(`Unknown argument: ${a}`);
    }
  }
  if (opts.dev && opts.devPort === opts.port) throw new Error("--dev-port must differ from --port");
  return opts;
}

/** The per-launch API token. --dev may pin it via REVIEW_DASHBOARD_TOKEN so a
 *  server restart doesn't invalidate the open Vite tab. */
export function chooseToken(dev: boolean, envToken: string | undefined): string {
  if (dev && envToken !== undefined && envToken.length > 0) {
    if (envToken.length < MIN_TOKEN_LENGTH) throw new Error(`REVIEW_DASHBOARD_TOKEN must be at least ${MIN_TOKEN_LENGTH} characters`);
    return envToken;
  }
  return randomBytes(32).toString("base64url");
}

function openBrowser(url: string): void {
  const cmd = process.platform === "darwin" ? "open" : process.platform === "win32" ? "cmd" : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  try {
    spawn(cmd, args, { detached: true, stdio: "ignore" }).on("error", () => undefined).unref();
  } catch {
    // Best effort: the URL is printed anyway.
  }
}

async function main(): Promise<void> {
  let args: DashboardArgs;
  try {
    args = parseDashboardArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${(e as Error).message}\n${USAGE}\n`);
    process.exit(2);
  }
  if (args.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }
  if (!args.reviewer) {
    process.stderr.write(`--reviewer is required.\n${USAGE}\n`);
    process.exit(2);
  }
  const token = chooseToken(args.dev, process.env.REVIEW_DASHBOARD_TOKEN);

  // adminInit initialises the Admin SDK as soon as it's imported, without a
  // projectId, so the project has to be in the environment first.
  process.env.GOOGLE_CLOUD_PROJECT ??= args.projectId;
  process.env.GCLOUD_PROJECT ??= args.projectId;
  const { startServer, StartupError } = await import("./server");

  try {
    const running = await startServer({
      port: args.port,
      projectId: args.projectId,
      reviewer: args.reviewer,
      devPort: args.dev ? args.devPort : null,
      ignoreMaintenance: args.ignoreMaintenance,
      token,
      staticDir: args.staticDir,
    });
    const url = `http://127.0.0.1:${args.dev ? args.devPort : args.port}/#t=${token}`;
    process.stdout.write(
      [
        "",
        "  Postbox review dashboard (PRODUCTION data)",
        `  project   ${args.projectId}`,
        `  reviewer  ${running.reviewer.displayName ?? "(no display name)"} (${running.reviewer.uid})`,
        `  points    ${running.pointsOverrideActive ? "Remote Config override active" : "defaults (no Remote Config override)"}`,
        `  reports   ${running.reportCount} loaded`,
        ...(running.maintenanceMode ? [`  NOTE      maintenance mode is ON${args.ignoreMaintenance ? " (ignored: reviews allowed)" : ", so reviews are blocked"}`] : []),
        "",
        `  open      ${url}`,
        "",
      ].join("\n") + "\n",
    );
    if (args.open) openBrowser(url);
    const shutdown = () => {
      process.stdout.write("\nShutting down...\n");
      running.close().then(() => process.exit(0)).catch(() => process.exit(1));
    };
    process.once("SIGINT", shutdown);
    process.once("SIGTERM", shutdown);
  } catch (e) {
    if (e instanceof StartupError) {
      process.stderr.write(`\n${e.message}\n${e.hint ? `\n${e.hint}\n` : ""}`);
      process.exit(1);
    }
    throw e;
  }
}

if (require.main === module) {
  main().catch((e) => {
    process.stderr.write(`${(e as Error).stack ?? String(e)}\n`);
    process.exit(1);
  });
}
