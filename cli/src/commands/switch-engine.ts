import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower switch engine [options]

Switch the focused browser pane's rendering engine.

Options:
  --webkit                  Switch to WebKit
  --chrome                  Switch to Chromium
  --help, -h                Show this help message

If no engine is specified, toggles between WebKit and Chromium.

Examples:
  watchtower switch engine
  watchtower switch engine --webkit
  watchtower switch engine --chrome`);
}

export async function switchEngine(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let engine: string | undefined;

  for (const arg of args) {
    if (arg === "--webkit") {
      engine = "webkit";
    } else if (arg === "--chrome") {
      engine = "chromium";
    } else if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      console.error(`Unexpected argument: ${arg}`);
      printUsage();
      process.exit(1);
    }
  }

  try {
    const response = await sendCommand({
      command: "switch-engine",
      paneId: getPaneId(),
      ...(engine && { engine }),
    });

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }

    if (response.engine) {
      console.log(`Switched to ${response.engine}`);
    }
  } catch (err) {
    console.error(`${(err as Error).message}`);
    process.exit(1);
  }
}
