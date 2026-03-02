import SwiftUI

struct CLIInstallSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var config = WatchtowerConfig.shared
    @State private var dontAskAgain = false
    @State private var installError: String?
    @State private var installed = false
    @State private var status: CLIInstallState = .notBundled

    var body: some View {
        let title = sheetTitle
        let description = sheetDescription
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(description)
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
                Label(successLabel, systemImage: "checkmark.circle.fill")
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

                    Button(actionLabel) {
                        installError = nil
                        do {
                            try CLIInstaller.install()
                            installed = true
                            status = CLIInstaller.status()
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
        .onAppear {
            status = CLIInstaller.status()
        }
        .onChange(of: dontAskAgain) { value in
            if value {
                config.cliInstallDismissed = true
            }
        }
    }

    private var actionLabel: String {
        switch status {
        case .installedOutdated:
            return "Update"
        default:
            return "Install"
        }
    }

    private var successLabel: String {
        switch status {
        case .installedOutdated:
            return "CLI updated successfully"
        default:
            return "CLI installed successfully"
        }
    }

    private var sheetTitle: String {
        switch status {
        case .installedOutdated:
            return "Update Watchtower CLI?"
        default:
            return "Install Watchtower CLI?"
        }
    }

    private var sheetDescription: String {
        let base = "The Watchtower CLI lets you open terminals, browsers, and manage panes from the command line. It will be installed to /usr/local/bin/watchtower."
        switch status {
        case .installedOutdated(let installed, let bundled):
            var details = ""
            if let installed, let bundled {
                details = " You have v\(installed) installed and v\(bundled) is bundled."
            } else if let bundled {
                details = " A newer bundled version (v\(bundled)) is available."
            }
            return base + details
        case .notInstalled(let bundled):
            if let bundled {
                return base + " Bundled version: v\(bundled)."
            }
            return base
        default:
            return base
        }
    }
}
