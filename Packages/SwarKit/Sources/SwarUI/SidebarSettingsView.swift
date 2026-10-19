import SwiftUI

struct SidebarSettingsView: View {
    @AppStorage("sidebarLayout") private var storedLayout = ""
    @State private var showingSections = false
    private var layout: SidebarLayout { SidebarLayout(serialized: storedLayout) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Customize", selection: $showingSections) {
                Text("Library Items").tag(false)
                Text("Sections").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if showingSections { groups } else { shortcuts }
            HStack {
                Text("Search and Settings stay visible.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { storedLayout = "" }
                    .disabled(layout == SidebarLayout())
            }
        }.padding(20)
    }

    private var shortcuts: some View {
        List {
            ForEach(layout.sections) { section in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { !layout.hidden.contains(section) }, set: { visible in
                        update { $0.setVisible(section, visible) }
                    })) {
                        Label(section.rawValue, systemImage: section.symbol)
                    }.toggleStyle(.checkbox)
                        .disabled(!layout.hidden.contains(section) && layout.visibleSections.count == 1)
                        .help("Show or hide " + section.rawValue)
                    Spacer()
                    arrows(section.rawValue, index: layout.sections.firstIndex(of: section) ?? 0, count: layout.sections.count) { from, to in
                        update { $0.moveSections(from: IndexSet(integer: from), to: to) }
                    }
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                }.padding(.vertical, 3)
            }.onMove { from, to in update { $0.moveSections(from: from, to: to) } }
        }.listStyle(.inset).accessibilityLabel("Sidebar library items")
    }

    private var groups: some View {
        List {
            ForEach(layout.groups) { group in
                HStack(spacing: 10) {
                    Toggle(group.title, isOn: Binding(get: { !layout.hiddenGroups.contains(group) }, set: { visible in
                        update { $0.setVisible(group, visible) }
                    })).toggleStyle(.checkbox).disabled(group == .library)
                    Spacer()
                    arrows(group.title, index: layout.groups.firstIndex(of: group) ?? 0, count: layout.groups.count) { from, to in
                        update { $0.moveGroups(from: IndexSet(integer: from), to: to) }
                    }
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                }.padding(.vertical, 3)
            }.onMove { from, to in update { $0.moveGroups(from: from, to: to) } }
        }.listStyle(.inset).accessibilityLabel("Sidebar sections")
    }

    private func arrows(_ title: String, index: Int, count: Int, move: @escaping (Int, Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Button { move(index, index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).accessibilityLabel("Move " + title + " up")
            Button { move(index, index + 2) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).accessibilityLabel("Move " + title + " down")
        }.buttonStyle(.borderless).font(.caption)
    }

    private func update(_ change: (inout SidebarLayout) -> Void) {
        var edited = layout
        change(&edited)
        storedLayout = edited.serialized
    }
}
