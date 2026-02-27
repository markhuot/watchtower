// CEF Helper Process
//
// Minimal entry point for CEF subprocess (renderer, GPU, utility).
// Calls cef_execute_process() which handles the subprocess lifecycle
// and never returns for subprocess types.

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char* argv[]) {
    // Log what type of process we're being launched as
    const char* process_type = "unknown";
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--type=", 7) == 0) {
            process_type = argv[i] + 7;
            break;
        }
    }
    fprintf(stderr, "[WatchtowerHelper] Launched as process type: %s (argc=%d)\n", process_type, argc);
    fflush(stderr);

    // Configure CEF API version before any other CEF calls.
    // This tells the DLL what API version the client was compiled against.
    const char* hash = cef_api_hash(CEF_API_VERSION, 0);
    fprintf(stderr, "[WatchtowerHelper] cef_api_hash returned: %s\n", hash ? hash : "(null)");
    fflush(stderr);

    // Set up main args
    cef_main_args_t main_args;
    main_args.argc = argc;
    main_args.argv = argv;

    // Execute the subprocess. For subprocess types (renderer, GPU, etc.),
    // this function does not return. For the browser process, it returns -1.
    fprintf(stderr, "[WatchtowerHelper] Calling cef_execute_process...\n");
    fflush(stderr);
    int exit_code = cef_execute_process(&main_args, NULL, NULL);
    fprintf(stderr, "[WatchtowerHelper] cef_execute_process returned: %d\n", exit_code);
    fflush(stderr);

    if (exit_code >= 0) {
        // Subprocess has completed
        return exit_code;
    }

    // If we get here, this was somehow launched as a browser process.
    // That shouldn't happen for the helper app.
    fprintf(stderr, "Watchtower Helper: unexpected browser process launch\n");
    return 1;
}
