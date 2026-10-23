import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SourceStore.shared
    @State private var editMode: EditMode = .inactive
    @State private var showAddSource = false
    @State private var showPermissions = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.footnote.monospacedDigit().weight(.semibold))
                                .frame(width: 24, height: 24)
                                .glassEffect(.regular, in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.host)
                                Text(source.kind.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove(perform: store.move)
                    .onDelete(perform: store.remove)

                    Button("Add Source", systemImage: "plus.circle.fill") { showAddSource = true }
                } header: {
                    HStack {
                        Text("Search Sources")
                        Spacer()
                        Button(editMode.isEditing ? "Done" : "Reorder") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                } footer: {
                    Text("Results come from the top source first. Lower sources are only used once the ones above run out of results. Swipe to delete.")
                }
                .sensoryFeedback(.selection, trigger: store.sources)

                Section {
                    Button("Restore Default Sources", role: .destructive) { store.resetToDefaults() }
                }

                Section("Permissions & Storage") {
                    Button {
                        showPermissions = true
                    } label: {
                        LabeledContent("Permissions", value: "Files, notifications, background")
                    }
                    LabeledContent("Saving to", value: DownloadLocation.displayName)
                }

                Section("Sharing") {
                    LabeledContent("Upload", value: "Disabled (leech only)")
                    LabeledContent("Seeding", value: "Never. Removed when complete.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showAddSource) { AddSourceView(store: store) }
            .sheet(isPresented: $showPermissions) { PermissionsView() }
        }
    }
}

private struct AddSourceView: View {
    let store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var kind: SourceConfig.Kind = .html
    @State private var kindEdited = false
    @State private var error: String?
    @State private var testState: TestState = .idle
    @State private var added = false

    enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("thepiratebay10.org", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) {
                            error = nil
                            testState = .idle
                            if !kindEdited, let url = SourceConfig.normalizedURL(from: address) {
                                kind = SourceConfig.guessKind(for: url)
                            }
                        }
                    Picker("Type", selection: $kind) {
                        ForEach(SourceConfig.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: kind) { kindEdited = true; testState = .idle }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Most Pirate Bay mirrors and proxies use the classic search page. Pick JSON API for apibay-style sites.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Source")
                            Spacer()
                            switch testState {
                            case .idle: EmptyView()
                            case .testing: ProgressView()
                            case .ok(let count): Label("\(count) results", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(SourceConfig.normalizedURL(from: address) == nil || testState == .testing)
                    if case .failed(let message) = testState {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do {
                            try store.add(address, kind: kind)
                            added = true
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sensoryFeedback(.success, trigger: added) { _, new in new }
            .sensoryFeedback(trigger: testState) { _, new in
                switch new {
                case .ok: .success
                case .failed: .error
                default: nil
                }
            }
        }
    }

    /// Runs a sample search so the user knows the address and type work before adding.
    private func test() async {
        guard let url = SourceConfig.normalizedURL(from: address) else { return }
        testState = .testing
        do {
            let page = try await SourceConfig(url: url, kind: kind).makeSource().fetchPage(query: "ubuntu", page: 1)
            testState = page.results.isEmpty ? .failed("No results. Check the address or try the other type.") : .ok(page.results.count)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
