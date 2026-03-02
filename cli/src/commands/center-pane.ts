import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower center pane

Scroll the container so the active pane is centered in the window.

Options:
  --help, -h                Show this help message`);
}

export async function centerPane(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  try {
    const response = await sendCommand({
      command: "center-pane",
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
