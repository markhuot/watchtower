import SwiftUI

struct CLIInstallSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var config = WatchtowerConfig.shared
    @State private var dontAskAgain = false
    @State private var installError: String?
    @State private var installed = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Install Watchtower CLI?")
                .font(.headline)

            Text("The Watchtower CLI lets you open terminals, browsers, and manage panes from the command line. It will be installed to /usr/local/bin/watchtower.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            if let error = installError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: 320)
            }

            if installed {
                Label("CLI installed successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                if !installed {
                    Button("Not Now") {
                        if dontAskAgain {
                            config.cliInstallDismissed = true
                        }
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)

                    Button("Install") {
                        installError = nil
                        do {
                            try CLIInstaller.install()
                            installed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                isPresented = false
                            }
                        } catch {
                            installError = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            if !installed {
                Toggle("Don't ask again", isOn: $dontAskAgain)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
