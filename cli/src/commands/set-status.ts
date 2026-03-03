import { sendCommand, getPaneId } from "../ipc.ts";

type StatusValue = "active" | "idle" | "failed";

function printUsage() {
  console.log(`Usage: watchtower set status [options] <status>

Set the status indicator of a terminal pane.

Arguments:
  status                    One of: active, idle, failed

Options:
  --pane <id>               Target pane ID (defaults to WATCHTOWER_PANE_ID)
  --help, -h                Show this help message

Examples:
  watchtower set status active
  watchtower set status --pane <pane-id> idle
  watchtower set status failed`);
}

function parseStatus(raw: string): StatusValue | undefined {
  const value = raw.toLowerCase();
  if (value === "active" || value === "idle" || value === "failed") {
    return value;
  }
  return undefined;
}

export async function setStatus(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let paneId: string | undefined;
  let statusRaw: string | undefined;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    if (!arg) {
      continue;
    }

    if (arg === "--pane") {
      if (!next) {
        console.error("Missing value for --pane");
        printUsage();
        process.exit(1);
      }
      paneId = next;
      i++;
      continue;
    }

    if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    }

    statusRaw = arg;
  }

  if (!statusRaw) {
    console.error("Missing required status argument.");
    printUsage();
    process.exit(1);
  }

  const status = parseStatus(statusRaw);
  if (!status) {
    console.error(`Invalid status: ${statusRaw}`);
    console.error("Expected one of: active, idle, failed");
    process.exit(1);
  }

  paneId = paneId ?? getPaneId();
  if (!paneId) {
    console.error("No pane context found.");
    console.error("Run from inside a Watchtower pane or provide --pane <id>.");
    process.exit(1);
  }

  try {
    const response = await sendCommand({
      command: "set-pane-status",
      paneId,
      status,
    });

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`${(err as Error).message}`);
    process.exit(1);
  }
}
