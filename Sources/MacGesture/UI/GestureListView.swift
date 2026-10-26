import MacGestureCore
import SwiftUI

struct GestureListView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<UUID>()
    @State private var editor: EditorRequest?

    private struct EditorRequest: Identifiable {
        let mapping: GestureMapping
        let isNew: Bool
        var id: UUID { mapping.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            let blocking = model.mappingIssues.filter { $0.severity != .warning }
            if !blocking.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocking) { IssueRow(issue: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            if model.activeProfile.mappings.isEmpty {
                ContentUnavailableView {
                    Label("No Gestures", systemImage: "hand.draw")
                } description: {
                    Text("Add a gesture to map it to an action.")
                } actions: {
                    Button("Add Gesture") { addMapping() }
                }
            } else {
                list
            }
        }
        .sheet(item: $editor) { request in
            MappingEditor(model: model, draft: request.mapping, isNew: request.isNew) { saved in
                save(saved)
            }
        }
    }

    private var header: some View {
        HStack {
            Picker("Profile", selection: $model.activeProfileID) {
                ForEach(model.configuration.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .frame(maxWidth: 260)
            Spacer()
            Button {
                addMapping()
            } label: {
                Label("Add Gesture", systemImage: "plus")
            }
            .keyboardShortcut("n")
        }
        .padding(16)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach($model.activeProfile.mappings) { $mapping in
                MappingRow(mapping: $mapping, issues: model.issues(for: mapping))
                    .tag(mapping.id)
            }
            .onMove { from, to in
                model.activeProfile.mappings.move(fromOffsets: from, toOffset: to)
            }
            .onDelete { offsets in
                model.activeProfile.mappings.remove(atOffsets: offsets)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Edit…") { edit(id) }
                Button("Duplicate") { duplicate(id) }
            }
            Button("Enable") { setEnabled(ids, true) }
            Button("Disable") { setEnabled(ids, false) }
            Divider()
            Button("Delete", role: .destructive) { delete(ids) }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
        .onDeleteCommand { delete(selection) }
    }

    private func addMapping() {
        editor = EditorRequest(mapping: GestureMapping(trigger: .swipe(3, .upRight), action: .none), isNew: true)
    }

    private func edit(_ id: UUID) {
        guard let mapping = model.activeProfile.mappings.first(where: { $0.id == id }) else { return }
        editor = EditorRequest(mapping: mapping, isNew: false)
    }

    private func duplicate(_ id: UUID) {
        guard let index = model.activeProfile.mappings.firstIndex(where: { $0.id == id }) else { return }
        let copy = model.activeProfile.mappings[index].duplicated()
        model.activeProfile.mappings.insert(copy, at: index + 1)
        selection = [copy.id]
    }

    private func setEnabled(_ ids: Set<UUID>, _ enabled: Bool) {
        var profile = model.activeProfile
        for index in profile.mappings.indices where ids.contains(profile.mappings[index].id) {
            profile.mappings[index].isEnabled = enabled
        }
        model.activeProfile = profile
    }

    private func delete(_ ids: Set<UUID>) {
        model.activeProfile.mappings.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    private func save(_ mapping: GestureMapping) {
        var profile = model.activeProfile
        if let index = profile.mappings.firstIndex(where: { $0.id == mapping.id }) {
            profile.mappings[index] = mapping
        } else {
            profile.mappings.append(mapping)
        }
        model.activeProfile = profile
        selection = [mapping.id]
    }
}

private struct MappingRow: View {
    @Binding var mapping: GestureMapping
    let issues: [MappingIssue]

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Enabled", isOn: $mapping.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Enable \(mapping.displayName)")
            GestureGlyph(trigger: mapping.trigger)
                .foregroundStyle(mapping.isEnabled ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.displayName)
                    .fontWeight(.medium)
                Text(mapping.trigger.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(mapping.action.summary, systemImage: mapping.action.category.symbolName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let worst = issues.max(by: { $0.severity < $1.severity }) {
                Image(systemName: worst.severity.style.symbolName)
                    .foregroundStyle(worst.severity.style.color)
                    .help(issues.map(\.message).joined(separator: "\n"))
                    .accessibilityLabel(issues.map(\.message).joined(separator: ". "))
            }
        }
        .opacity(mapping.isEnabled ? 1 : 0.6)
        .padding(.vertical, 2)
    }
}
