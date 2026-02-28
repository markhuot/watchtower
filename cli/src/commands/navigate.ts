import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower navigate <url>

Navigate the focused browser pane to a URL.

Arguments:
  url                       The URL to navigate to

Options:
  --help, -h                Show this help message

If no scheme is provided, https:// is prepended automatically.

Examples:
  watchtower navigate https://example.com
  watchtower navigate example.com
  watchtower navigate localhost:3000`);
}

export async function navigate(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let url: string | undefined;

  for (const arg of args) {
    if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      url = arg;
    }
  }

  if (!url) {
    console.error("Missing required url argument.");
    printUsage();
    process.exit(1);
  }

  // Prepend https:// if no scheme is provided
  if (!url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)) {
    url = `https://${url}`;
  }

  try {
    const response = await sendCommand({
      command: "navigate",
      paneId: getPaneId(),
      url,
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
