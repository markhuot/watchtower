import { homedir } from "os";
import { dirname, join } from "path";
import { access, mkdir, readFile, writeFile } from "fs/promises";

const PLUGIN_FILE_NAME = "watchtower.js";

const PLUGIN_SOURCE = `export const WatchtowerPlugin = async ({ $, client }) => {
  const paneId = process.env.WATCHTOWER_PANE_ID;
  const home = process.env.HOME || ".";
  const logPath = process.env.WATCHTOWER_OPENCODE_EVENT_LOG || home + "/.config/watchtower/opencode-events.log";
  let lastStatus;

  if (!paneId) {
    await client.app.log({
      body: {
        service: "watchtower-plugin",
        level: "warn",
        message: "WATCHTOWER_PANE_ID missing; plugin disabled for this process",
      },
    });
  }

  const setWatchtowerStatus = async (status) => {
    if (!paneId) {
      return;
    }

    if (status === lastStatus) {
      return;
    }

    try {
      await $\`watchtower set status --pane \${paneId} \${status}\`;
      lastStatus = status;
    } catch (error) {
      await client.app.log({
        body: {
          service: "watchtower-plugin",
          level: "warn",
          message: "Failed to send status",
          extra: {
            status,
            error: String(error),
          },
        },
      });
    }
  };

  const appendEventLog = async (eventType) => {
    try {
      const timestamp = new Date().toISOString();
      const line = "[" + timestamp + "] " + eventType;
      await $\`mkdir -p \${home + "/.config/watchtower"}\`;
      await $\`printf "%s\\n" \${line} >> \${logPath}\`;
    } catch {
      // Logging should never break plugin behavior.
    }
  };

  return {
    event: async ({ event }) => {
      await appendEventLog(event.type);

      if (event.type === "session.created") {
        await setWatchtowerStatus("active");
      }

      if (event.type === "session.idle") {
        await setWatchtowerStatus("idle");
      }

      if (event.type === "permission.asked") {
        await setWatchtowerStatus("failed");
      }

      if (event.type === "permission.replied") {
        await setWatchtowerStatus("active");
      }

      if (event.type === "session.error") {
        await setWatchtowerStatus("failed");
      }

      if (
        event.type === "message.updated" ||
        event.type === "message.part.updated" ||
        event.type === "tool.execute.before" ||
        event.type === "command.executed" ||
        event.type === "session.status" ||
        event.type === "session.updated"
      ) {
        await setWatchtowerStatus("active");
      }
    },
  };
};
`;

function printUsage() {
  console.log(`Usage: watchtower install opencode [options]

Install the Watchtower OpenCode plugin.

Options:
  --project                 Install to project-local .opencode/plugins
  --directory, -d <path>    Base directory for --project mode (default: cwd)
  --force                   Overwrite existing plugin file
  --help, -h                Show this help message

Examples:
  watchtower install opencode
  watchtower install opencode --project
  watchtower install opencode --project -d ~/src/my-repo
  watchtower install opencode --force`);
}

interface InstallOptions {
  project: boolean;
  directory?: string;
  force: boolean;
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

function getInstallPath(options: InstallOptions): string {
  if (options.project) {
    const base = options.directory ?? process.cwd();
    return join(base, ".opencode", "plugins", PLUGIN_FILE_NAME);
  }

  return join(homedir(), ".config", "opencode", "plugins", PLUGIN_FILE_NAME);
}

export async function installOpencode(args: string[]) {
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

  const targetPath = getInstallPath(options);

  try {
    await mkdir(dirname(targetPath), { recursive: true });

    let exists = true;
    try {
      await access(targetPath);
    } catch {
      exists = false;
    }

    if (exists && !options.force) {
      const content = await readFile(targetPath, "utf8");
      if (content.trim().length > 0) {
        console.error(`Plugin already exists: ${targetPath}`);
        console.error("Re-run with --force to overwrite.");
        process.exit(1);
      }
    }

    await writeFile(targetPath, PLUGIN_SOURCE, "utf8");

    const pluginDir = dirname(targetPath);
    console.log(`Installed OpenCode plugin at: ${targetPath}`);
    console.log(`OpenCode plugin directory: ${pluginDir}`);
    console.log("Restart OpenCode sessions to load the plugin.");
  } catch (error) {
    console.error(`Failed to install plugin: ${(error as Error).message}`);
    process.exit(1);
  }
}
