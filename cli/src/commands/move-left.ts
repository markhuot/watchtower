import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower move left

Move the focused pane one position to the left (wraps around).

Options:
  --help, -h                Show this help message`);
}

export async function moveLeft(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  try {
    const response = await sendCommand({
      command: "move-pane-left",
      paneId: getPaneId(),
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
