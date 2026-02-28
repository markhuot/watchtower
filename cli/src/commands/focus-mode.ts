import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower focus mode

Toggle focus mode on the currently focused pane.

Options:
  --help, -h                Show this help message`);
}

export async function focusMode(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  try {
    const response = await sendCommand({
      command: "focus-mode",
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
