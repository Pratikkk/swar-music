import SwiftUI
import Library

@MainActor
struct SmartPlaylistEditorView: View {
    let library: LibraryModel
    let playlist: LibraryPlaylist?
    let onSaved: (LibraryPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var definition: SmartPlaylistDefinition
    @State private var decodingError: String?
    @State private var error: String?
    @State private var preview: SmartPlaylistPreview?
    @State private var loading = false
    @State private var saving = false
    @State private var limitText: String

    init(library: LibraryModel, playlist: LibraryPlaylist? = nil, onSaved: @escaping (LibraryPlaylist) -> Void) {
        self.library = library; self.playlist = playlist; self.onSaved = onSaved
        _name = State(initialValue: playlist?.name ?? "New Smart Playlist")
        var rules = SmartPlaylistDefinition(rules: [SmartRule(field: .favourite)])
        var problem: String?
        if let json = playlist?.smartRulesJSON {
            do { rules = try .decode(json) } catch { problem = "Saved rules could not be opened: " + error.localizedDescription }
        }
        _definition = State(initialValue: rules)
        _decodingError = State(initialValue: problem)
        _limitText = State(initialValue: String(rules.limit ?? 100))
    }

    private var validation: String? {
        if let decodingError { return decodingError }
        do { try definition.validate(); return nil } catch { return error.localizedDescription }
    }
    private struct PreviewKey: Hashable {
        let definition: SmartPlaylistDefinition
        let ready: Bool
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(playlist == nil ? "New Smart Playlist" : "Edit Smart Playlist").font(.title2.bold())
                Spacer()
                Menu("Presets") {
                    Button("Favourites") { definition = .init(rules: [SmartRule(field: .favourite)]) }
                    Button("Recently Added") { definition = .init(rules: [SmartRule(field: .added)], sort: .recentlyAdded) }
                    Button("Lossless") { definition = .init(rules: [SmartRule(field: .lossless)]) }
                }.fixedSize().disabled(saving || decodingError != nil)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Smart Playlist name")
                    HStack {
                        Text("Match")
                        Picker("Match", selection: $definition.mode) {
                            ForEach(SmartMatchMode.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 90)
                        Text("of these rules")
                        Spacer()
                        Button("Add Rule", systemImage: "plus") { definition.rules.append(SmartRule()) }
                            .disabled(definition.rules.count >= 20)
                    }
                    VStack(spacing: 10) {
                        ForEach($definition.rules) { $rule in
                            let id = rule.id
                            SmartRuleRow(rule: $rule, number: (definition.rules.firstIndex { $0.id == id } ?? 0) + 1,
                                canRemove: definition.rules.count > 1) { definition.rules.removeAll { $0.id == id } }
                        }
                    }
                    Divider()
                    HStack {
                        Picker("Sort by", selection: $definition.sort) {
                            ForEach(TrackSortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }.frame(width: 260)
                        Toggle("Reverse order", isOn: $definition.reversed)
                    }
                    HStack {
                        Toggle("Limit to", isOn: Binding(get: { definition.limit != nil }, set: { definition.limit = $0 ? (Int(limitText) ?? 0) : nil }))
                            .fixedSize()
                        TextField("100", text: $limitText).frame(width: 80).textFieldStyle(.roundedBorder)
                            .disabled(definition.limit == nil).accessibilityLabel("Song limit")
                            .onChange(of: limitText) { _, value in if definition.limit != nil { definition.limit = Int(value) ?? 0 } }
                        Text("songs").foregroundStyle(.secondary)
                    }
                    Divider()
                    previewContent
                }.padding(20)
            }.disabled(saving || decodingError != nil)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || validation != nil || preview == nil || error != nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
            }.padding(16)
        }.frame(width: 690, height: 620).background(SwarTheme.canvas)
        .task(id: PreviewKey(definition: definition, ready: library.isReady, revision: library.overviewRevision)) { await refreshPreview() }
    }

    @ViewBuilder private var previewContent: some View {
        if let problem = validation ?? error {
            Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        } else if let preview {
            HStack {
                Text("\(preview.selectedCount) \(preview.selectedCount == 1 ? "song" : "songs")").font(.headline)
                if preview.selectedCount < preview.matchedCount { Text("of \(preview.matchedCount) matches").foregroundStyle(.secondary) }
                Spacer()
            }
            if preview.samples.isEmpty { Text("No songs match these rules.").foregroundStyle(.secondary) }
            ForEach(preview.samples) { track in
                HStack(spacing: 10) {
                    CoverArt(url: library.artworkURL(track.artworkKey), title: track.album, maximumPixelSize: 128).frame(width: 28, height: 28)
                    Text(track.title).lineLimit(1)
                    Spacer()
                    Text(track.artist).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 240, alignment: .trailing)
                }.font(.caption)
            }
        } else if loading { ProgressView("Updating preview…").controlSize(.small) }
    }

    private func refreshPreview() async {
        preview = nil; error = nil
        guard validation == nil else { return }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await library.smartPlaylistPreview(definition)
            guard !Task.isCancelled else { return }
            preview = result; loading = false
        } catch is CancellationError { }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
    }
    private func save() {
        guard !saving, validation == nil else { return }
        saving = true
        let name = name, definition = definition
        Task {
            do {
                let result = try await library.saveSmartPlaylist(id: playlist?.id, name: name, definition: definition)
                onSaved(result); dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let number: Int
    let canRemove: Bool
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $rule.field) {
                ForEach(SmartField.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 126).accessibilityLabel("Rule \(number) field")
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(rule.field.comparisons) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 160).accessibilityLabel("Rule \(number) comparison")
            if rule.field == .favourite || rule.field == .lossless {
                Picker("Value", selection: $rule.value) { Text("Yes").tag("true"); Text("No").tag("false") }
                    .labelsHidden().accessibilityLabel("Rule \(number) value")
            } else {
                TextField(rule.field.initialValue.isEmpty ? "Value" : rule.field.initialValue, text: $rule.value)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Rule \(number) value")
                if rule.field == .bitrate { Text("kbps").font(.caption).foregroundStyle(.secondary) }
                if rule.field == .added { Text(rule.comparison == .olderDays ? "days ago" : "days").font(.caption).foregroundStyle(.secondary) }
            }
            Button(action: remove) { Image(systemName: "minus.circle").frame(width: 22, height: 22) }
                .buttonStyle(.plain).disabled(!canRemove).accessibilityLabel("Remove rule \(number)")
        }
        .onChange(of: rule.field) { _, field in rule.comparison = field.comparisons[0]; rule.value = field.initialValue }
    }
}
