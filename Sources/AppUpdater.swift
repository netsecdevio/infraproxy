import Cocoa
import Combine
import Sparkle
import SwiftUI

final class AppUpdater: ObservableObject {
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
    }
    func start() { controller.startUpdater() }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        // Sparkle validates the menu item while a check or installation is in progress.
        item.target = controller
        return item
    }
}

struct UpdatesView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Software updates", systemImage: "arrow.down.circle").font(.title.bold())
            Text("infravibe \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.title2)
            Text("Get new features and fixes without downloading and replacing the app yourself.")
                .foregroundStyle(.secondary)
            Toggle("Automatically check for new releases", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            Text("infravibe checks daily and notifies you when an update is available. You choose when to install it.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
            Text("Installing an update restarts infravibe. Updates and the release feed are signed and verified before installation.")
                .font(.caption).foregroundStyle(.secondary)
            Link("View release history", destination: URL(string: "https://github.com/netsecdevio/infravibe/releases")!)
            Spacer()
        }.padding(28)
    }
}
