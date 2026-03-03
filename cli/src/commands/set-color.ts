import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower set color [options] [color]

Set the header color of a pane.

Arguments:
  color                     Hex color (#RGB, #RRGGBB, RGB, or RRGGBB).
                            Omit to reset to the default theme color.

Options:
  --pane <id>              Target pane ID (defaults to WATCHTOWER_PANE_ID)
  --reset                   Reset to the default theme color
  --help, -h                Show this help message

Examples:
  watchtower set color #ff0000
  watchtower set color --pane <pane-id> #ff0000
  watchtower set color 00ff00
  watchtower set color f0f
  watchtower set color --reset`);
}

export async function setColor(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  const reset = args.includes("--reset");
  let color: string | undefined;
  let paneId: string | undefined;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

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

    if (arg === "--reset") continue;
    if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      color = arg;
    }
  }

  paneId = paneId ?? getPaneId();
  if (!paneId) {
    console.error("No pane context found.");
    console.error("Run from inside a Watchtower pane or provide --pane <id>.");
    process.exit(1);
  }

  // Build the command payload
  const payload: Record<string, unknown> = {
    command: "set-pane-color",
    paneId,
  };

  if (reset || !color) {
    // Reset to default — send null color
    payload.color = null;
  } else {
    // Normalize: strip # prefix, validate hex
    let hex = color.replace(/^#/, "");

    // Expand 3-digit to 6-digit
    if (/^[0-9a-fA-F]{3}$/.test(hex)) {
      hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    }

    if (!/^[0-9a-fA-F]{6}$/.test(hex)) {
      console.error(`Invalid hex color: ${color}`);
      console.error("Expected format: #RGB, #RRGGBB, RGB, or RRGGBB");
      process.exit(1);
    }

    payload.color = `#${hex.toUpperCase()}`;
  }

  try {
    const response = await sendCommand(payload);

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`${(err as Error).message}`);
    process.exit(1);
  }
}
