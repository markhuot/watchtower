import SwiftUI

/// A dialog sheet that presents fields for an action's arguments.
/// Supports text fields (default) and dropdown pickers (when @options is declared).
struct ActionDialogView: View {
    @Binding var isPresented: Bool
    let action: Action
    let workingDirectory: String
    let onRun: ([String: String]) -> Void

    @State private var fieldValues: [String: String] = [:]
    @State private var fieldErrors: [String: String] = [:]
    @State private var resolvedOptions: [String: [String]] = [:]
    @State private var optionsFailed: Set<String> = []
    @State private var isLoading: Bool = true

    /// Whether all required fields have non-empty values.
    private var canRun: Bool {
        guard !isLoading else { return false }
        for arg in action.arguments {
            let value = fieldValues[arg.variableName] ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(action.displayName)
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            if let desc = action.descriptionText {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 12)
            } else {
                Spacer().frame(height: 12)
            }

            // Form fields
            VStack(alignment: .leading, spacing: 12) {
                ForEach(action.arguments) { arg in
                    argumentField(for: arg)
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

                Button("Run") {
                    onRun(fieldValues)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: max(200, CGFloat(80 + action.arguments.count * 70)))
        .task {
            await resolveDefaultsAndOptions()
            isLoading = false
        }
    }

    @ViewBuilder
    private func argumentField(for arg: ActionArgument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(arg.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if let opts = resolvedOptions[arg.variableName], !optionsFailed.contains(arg.variableName) {
                // Dropdown picker
                Picker("", selection: Binding(
                    get: { fieldValues[arg.variableName] ?? "" },
                    set: { fieldValues[arg.variableName] = $0 }
                )) {
                    ForEach(opts, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
            } else if isLoading && hasAsyncValue(for: arg.variableName) {
                // Loading placeholder
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
            } else {
                // Text field
                TextField("", text: Binding(
                    get: { fieldValues[arg.variableName] ?? "" },
                    set: { fieldValues[arg.variableName] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Error hint
            if let error = fieldErrors[arg.variableName] {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
    }

    /// Whether this argument has an async default or options value.
    private func hasAsyncValue(for variableName: String) -> Bool {
        if let defaultVal = action.defaults[variableName], defaultVal.hasPrefix("$(") {
            return true
        }
        if let optionsVal = action.options[variableName], optionsVal.hasPrefix("$(") {
            return true
        }
        return false
    }

    /// Resolve all @default and @options values concurrently.
    private func resolveDefaultsAndOptions() async {
        // Initialize field values with static defaults
        var initialValues: [String: String] = [:]
        for arg in action.arguments {
            if let defaultVal = action.defaults[arg.variableName] {
                if !defaultVal.hasPrefix("$(") {
                    initialValues[arg.variableName] = defaultVal
                }
            }
        }

        // Resolve static options
        for arg in action.arguments {
            if let optionsVal = action.options[arg.variableName] {
                if !optionsVal.hasPrefix("$(") {
                    // Static comma-separated list
                    let opts = optionsVal.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    await MainActor.run {
                        resolvedOptions[arg.variableName] = opts
                        // If no default set, select first option
                        if initialValues[arg.variableName] == nil, let first = opts.first {
                            initialValues[arg.variableName] = first
                        }
                    }
                }
            }
        }

        await MainActor.run {
            fieldValues = initialValues
        }

        // Resolve async values concurrently
        await withTaskGroup(of: (String, AsyncResolveResult).self) { group in
            for arg in action.arguments {
                let varName = arg.variableName

                // Resolve async options
                if let optionsVal = action.options[varName], optionsVal.hasPrefix("$(") {
                    let cmd = String(optionsVal.dropFirst(2).dropLast(1))
                    group.addTask {
                        let result = await self.runShellCommand(cmd)
                        return (varName, .options(result))
                    }
                }

                // Resolve async defaults
                if let defaultVal = action.defaults[varName], defaultVal.hasPrefix("$(") {
                    let cmd = String(defaultVal.dropFirst(2).dropLast(1))
                    group.addTask {
                        let result = await self.runShellCommand(cmd)
                        return (varName, .defaultValue(result))
                    }
                }
            }

            for await (varName, result) in group {
                await MainActor.run {
                    switch result {
                    case .options(let shellResult):
                        if let output = shellResult {
                            let opts = output.components(separatedBy: .newlines)
                                .filter { !$0.isEmpty }
                            resolvedOptions[varName] = opts
                            // If no value set yet, select first option
                            if fieldValues[varName]?.isEmpty != false, let first = opts.first {
                                fieldValues[varName] = first
                            }
                        } else {
                            optionsFailed.insert(varName)
                            fieldErrors[varName] = "Options command failed"
                        }

                    case .defaultValue(let shellResult):
                        if let output = shellResult {
                            // Only set if the field hasn't been set by options already
                            // or if there are options, use it to select the right option
                            if resolvedOptions[varName] != nil {
                                // Has options — use default to pre-select
                                fieldValues[varName] = output
                            } else if fieldValues[varName]?.isEmpty != false {
                                fieldValues[varName] = output
                            }
                        } else {
                            fieldErrors[varName] = "Default command failed"
                        }
                    }
                }
            }
        }
    }

    private enum AsyncResolveResult {
        case defaultValue(String?)
        case options(String?)
    }

    /// Run a shell command and return trimmed stdout, or nil on failure.
    private func runShellCommand(_ command: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                continuation.resume(returning: nil)
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(returning: output)
        }
    }
}
