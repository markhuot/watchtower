import SwiftUI

/// Sheet dialog for creating a new workspace.
/// Presents workspace name and base branch fields.
struct WorkspaceDialogView: View {
    @Binding var isPresented: Bool
    let repoRoot: String
    let onSubmit: (String, String) -> Void

    @State private var workspaceName: String = WordList.randomName()
    @State private var baseBranch: String = ""
    @State private var isLoadingBranch: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("New Workspace")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // Form fields
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("workspace-name", text: $workspaceName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Base branch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    if isLoadingBranch {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Detecting branch...")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        }
                    } else {
                        TextField("main", text: $baseBranch)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 20)

            // Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("OK") {
                    onSubmit(workspaceName, baseBranch)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 360, height: 240)
        .task {
            let branch = await WorkspaceManager.currentBranch(for: repoRoot)
            await MainActor.run {
                baseBranch = branch
                isLoadingBranch = false
            }
        }
    }
}
