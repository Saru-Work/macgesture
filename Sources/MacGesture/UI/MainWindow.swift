import MacGestureCore
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.configurationNotice {
                    NoticeBanner(text: notice, style: .warning) { model.dismissConfigurationNotice() }
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(model.selectedSection.title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.isEnabled) {
                    Label(model.isEnabled ? "Enabled" : "Paused", systemImage: model.isEnabled ? "hand.point.up.left.fill" : "hand.raised.slash")
                }
                .toggleStyle(.button)
                .help(model.isEnabled ? "Pause gesture processing" : "Resume gesture processing")
            }
        }
        .onAppear { model.refreshSystemState() }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection {
        case .dashboard: DashboardView(model: model)
        case .gestures: GestureListView(model: model)
        case .liveTest: LiveTestView(model: model)
        case .permissions: PermissionsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .permissions:
            model.actionsNeedingPermission.isEmpty || model.permissions.allGranted ? 0 : 1
        case .gestures:
            model.mappingIssues.filter { $0.severity == .error }.count
        default:
            0
        }
    }
}
