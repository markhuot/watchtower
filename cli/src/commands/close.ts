import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower close [pane-id]

Close a pane in the current Watchtower window.

Arguments:
  pane-id                   UUID of the pane to close. If omitted, closes
                            the pane identified by WATCHTOWER_PANE_ID.

Options:
  --help, -h                Show this help message

Examples:
  watchtower close
  watchtower close 123e4567-e89b-12d3-a456-426614174000`);
}

export async function closePane(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  // The pane ID is either the first positional argument or from the environment
  let targetPaneId: string | undefined;

  for (const arg of args) {
    if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      targetPaneId = arg;
    }
  }

  if (!targetPaneId) {
    targetPaneId = getPaneId();
  }

  if (!targetPaneId) {
    console.error("No pane ID specified and WATCHTOWER_PANE_ID is not set.");
    console.error("Either provide a pane ID argument or run from inside a Watchtower terminal.");
    process.exit(1);
  }

  try {
    const response = await sendCommand({
      command: "close-pane",
      paneId: targetPaneId,
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
