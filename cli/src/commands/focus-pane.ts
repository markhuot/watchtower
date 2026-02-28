import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower focus pane <pane-id>

Focus a specific pane by its UUID.

Arguments:
  pane-id                   UUID of the pane to focus

Options:
  --help, -h                Show this help message

Examples:
  watchtower focus pane 123e4567-e89b-12d3-a456-426614174000`);
}

export async function focusPane(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

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
    console.error("Missing required pane-id argument.");
    printUsage();
    process.exit(1);
  }

  try {
    const response = await sendCommand({
      command: "focus-pane",
      paneId: getPaneId(),
      targetPaneId,
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
