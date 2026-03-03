import { homedir } from "os";
import { dirname, join, resolve } from "path";
import { access, mkdir, readFile, writeFile } from "fs/promises";

const HOOK_DIR_NAME = "watchtower-hooks";

const ACTIVE_HOOK_SCRIPT = `#!/bin/bash
set -euo pipefail

pane_id="\${WATCHTOWER_PANE_ID:-}"
if [ -z "$pane_id" ]; then
  exit 0
fi

watchtower set status --pane "$pane_id" active >/dev/null 2>&1 || true
`;

const IDLE_HOOK_SCRIPT = `#!/bin/bash
set -euo pipefail

pane_id="\${WATCHTOWER_PANE_ID:-}"
if [ -z "$pane_id" ]; then
  exit 0
fi

watchtower set status --pane "$pane_id" idle >/dev/null 2>&1 || true
`;

const FAILED_HOOK_SCRIPT = `#!/bin/bash
set -euo pipefail

pane_id="\${WATCHTOWER_PANE_ID:-}"
if [ -z "$pane_id" ]; then
  exit 0
fi

watchtower set status --pane "$pane_id" failed >/dev/null 2>&1 || true
`;

type JSONValue =
  | string
  | number
  | boolean
  | null
  | { [key: string]: JSONValue }
  | JSONValue[];

interface HookHandler {
  type: "command";
  command: string;
}

interface HookMatcherGroup {
  matcher?: string;
  hooks: HookHandler[];
}

interface ClaudeSettings {
  hooks?: Record<string, HookMatcherGroup[]>;
  [key: string]: JSONValue | undefined;
}

interface InstallOptions {
  project: boolean;
  directory?: string;
  force: boolean;
}

function printUsage() {
  console.log(`Usage: watchtower install claude [options]

Install Watchtower Claude hooks for status updates.

Options:
  --project                 Install to project-local .claude/settings.json
  --directory, -d <path>    Base directory for --project mode (default: cwd)
  --force                   Replace existing Watchtower Claude hooks
  --help, -h                Show this help message

Examples:
  watchtower install claude
  watchtower install claude --project
  watchtower install claude --project -d ~/src/my-repo
  watchtower install claude --force`);
}

function parseArgs(args: string[]): InstallOptions {
  const options: InstallOptions = {
    project: false,
    force: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    if (arg === "--project") {
      options.project = true;
      continue;
    }

    if (arg === "--force") {
      options.force = true;
      continue;
    }

    if ((arg === "--directory" || arg === "-d") && next) {
      options.directory = next;
      i++;
      continue;
    }

    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

function getSettingsPath(options: InstallOptions): string {
  if (options.project) {
    const base = resolve(options.directory ?? process.cwd());
    return join(base, ".claude", "settings.json");
  }

  return join(homedir(), ".claude", "settings.json");
}

function getHookDir(options: InstallOptions): string {
  if (options.project) {
    const base = resolve(options.directory ?? process.cwd());
    return join(base, ".claude", "hooks", HOOK_DIR_NAME);
  }

  return join(homedir(), ".claude", "hooks", HOOK_DIR_NAME);
}

async function readSettings(settingsPath: string): Promise<ClaudeSettings> {
  try {
    const raw = await readFile(settingsPath, "utf8");
    if (raw.trim().length === 0) {
      return {};
    }

    const parsed = JSON.parse(raw) as ClaudeSettings;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("settings.json must contain a JSON object");
    }

    return parsed;
  } catch (error) {
    const message = (error as Error).message;
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return {};
    }

    throw new Error(`Could not read Claude settings at ${settingsPath}: ${message}`);
  }
}

function ensureGroup(
  hooks: Record<string, HookMatcherGroup[]>,
  eventName: string,
  matcher: string | undefined,
): HookMatcherGroup {
  const groups = hooks[eventName] ?? [];
  hooks[eventName] = groups;

  const existing = groups.find((group) => (group.matcher ?? "") === (matcher ?? ""));
  if (existing) {
    existing.hooks = Array.isArray(existing.hooks) ? existing.hooks : [];
    return existing;
  }

  const created: HookMatcherGroup = {
    ...(matcher ? { matcher } : {}),
    hooks: [],
  };
  groups.push(created);
  return created;
}

function upsertCommandHook(group: HookMatcherGroup, command: string) {
  const hasHook = group.hooks.some(
    (hook) => hook.type === "command" && hook.command === command,
  );
  if (!hasHook) {
    group.hooks.push({ type: "command", command });
  }
}

function removeWatchtowerHooks(settings: ClaudeSettings, hookDir: string) {
  if (!settings.hooks) {
    return;
  }

  const hookPrefix = hookDir.endsWith("/") ? hookDir : `${hookDir}/`;
  const legacyHookPattern = new RegExp(
    `(?:^|[\\\\/])${HOOK_DIR_NAME}[\\\\/](set-active|set-idle|set-failed)\\.sh$`,
  );
  for (const [eventName, groups] of Object.entries(settings.hooks)) {
    const filteredGroups: HookMatcherGroup[] = [];

    for (const group of groups ?? []) {
      const keptHooks = (group.hooks ?? []).filter(
        (hook) =>
          !(
            hook.type === "command" &&
            (hook.command.startsWith(hookPrefix) || legacyHookPattern.test(hook.command))
          ),
      );

      if (keptHooks.length > 0) {
        filteredGroups.push({
          ...group,
          hooks: keptHooks,
        });
      }
    }

    if (filteredGroups.length > 0) {
      settings.hooks[eventName] = filteredGroups;
    } else {
      delete settings.hooks[eventName];
    }
  }
}

function addWatchtowerHooks(settings: ClaudeSettings, hookDir: string) {
  if (!settings.hooks || typeof settings.hooks !== "object") {
    settings.hooks = {};
  }

  const activeCommand = join(hookDir, "set-active.sh");
  const idleCommand = join(hookDir, "set-idle.sh");
  const failedCommand = join(hookDir, "set-failed.sh");

  const activeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart"];
  for (const eventName of activeEvents) {
    const group = ensureGroup(settings.hooks, eventName, undefined);
    upsertCommandHook(group, activeCommand);
  }

  const idleEvents = ["Stop", "SessionEnd"];
  for (const eventName of idleEvents) {
    const group = ensureGroup(settings.hooks, eventName, undefined);
    upsertCommandHook(group, idleCommand);
  }

  const failedGroup = ensureGroup(settings.hooks, "Notification", "permission_prompt");
  upsertCommandHook(failedGroup, failedCommand);

  const failedToolGroup = ensureGroup(settings.hooks, "PostToolUseFailure", undefined);
  upsertCommandHook(failedToolGroup, failedCommand);
}

async function writeHookScripts(hookDir: string) {
  await mkdir(hookDir, { recursive: true });
  await writeFile(join(hookDir, "set-active.sh"), ACTIVE_HOOK_SCRIPT, { mode: 0o755 });
  await writeFile(join(hookDir, "set-idle.sh"), IDLE_HOOK_SCRIPT, { mode: 0o755 });
  await writeFile(join(hookDir, "set-failed.sh"), FAILED_HOOK_SCRIPT, { mode: 0o755 });
}

export async function installClaude(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let options: InstallOptions;
  try {
    options = parseArgs(args);
  } catch (error) {
    console.error((error as Error).message);
    printUsage();
    process.exit(1);
  }

  const settingsPath = getSettingsPath(options);
  const hookDir = getHookDir(options);

  try {
    const settingsDir = dirname(settingsPath);
    await mkdir(settingsDir, { recursive: true });

    let hadExistingSettings = true;
    try {
      await access(settingsPath);
    } catch {
      hadExistingSettings = false;
    }

    const settings = await readSettings(settingsPath);
    await writeHookScripts(hookDir);

    if (options.force) {
      removeWatchtowerHooks(settings, hookDir);
    }

    addWatchtowerHooks(settings, hookDir);

    await writeFile(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");

    console.log(`Installed Claude hooks at: ${hookDir}`);
    console.log(`Updated Claude settings: ${settingsPath}`);
    if (!hadExistingSettings) {
      console.log("Created new Claude settings file.");
    }
    console.log("Restart Claude sessions to load updated hooks.");
  } catch (error) {
    console.error(`Failed to install Claude hooks: ${(error as Error).message}`);
    process.exit(1);
  }
}
