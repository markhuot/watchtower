import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower new terminal [options] [-- <command> ...]

Open a new terminal pane in the current Watchtower window.

Options:
  --directory, -d <path>    Working directory for the new terminal
  --help, -h                Show this help message

Everything after "--" is run as a command in the new terminal.
The terminal stays open after the command exits so output is not lost.

Examples:
  watchtower new terminal
  watchtower new terminal -d ~/projects
  watchtower new terminal -- ps aux
  watchtower new terminal -d /tmp -- ls -la

The new terminal opens adjacent to the pane where this command is run.
If not running inside Watchtower, it opens in the first available window.`);
}

export async function newTerminal(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  // Split on "--" to separate options from the trailing command
  const ddIndex = args.indexOf("--");
  const optionArgs = ddIndex >= 0 ? args.slice(0, ddIndex) : args;
  const command =
    ddIndex >= 0 ? args.slice(ddIndex + 1).join(" ") || undefined : undefined;

  // Parse options
  let directory: string | undefined;

  for (let i = 0; i < optionArgs.length; i++) {
    const arg = optionArgs[i];
    const next = optionArgs[i + 1];
    if ((arg === "--directory" || arg === "-d") && next) {
      directory = next;
      i++;
    } else {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    }
  }

  const paneId = getPaneId();

  try {
    const response = await sendCommand({
      command: "new-terminal",
      paneId,
      ...(directory && { directory }),
      ...(command && { shellCommand: command }),
    });

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }

    // Output the new pane ID so scripts can use it
    if (response.paneId) {
      console.log(response.paneId);
    }
  } catch (err) {
    console.error(`${(err as Error).message}`);
    process.exit(1);
  }
}
