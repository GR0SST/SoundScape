import AppKit
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @Published var isSettingsPresented = false

    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon)
            applyDockIconVisibility()
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            UserDefaults.standard.set(
                showMenuBarIcon,
                forKey: Keys.showMenuBarIcon
            )
        }
    }

    init() {
        showDockIcon = UserDefaults.standard.object(
            forKey: Keys.showDockIcon
        ) as? Bool ?? true
        showMenuBarIcon = UserDefaults.standard.object(
            forKey: Keys.showMenuBarIcon
        ) as? Bool ?? true
    }

    func applyDockIconVisibility() {
        let policy: NSApplication.ActivationPolicy = showDockIcon
            ? .regular
            : .accessory
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
    }

    private enum Keys {
        static let showDockIcon = "show_dock_icon"
        static let showMenuBarIcon = "show_menu_bar_icon"
    }
}

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.055))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Settings")
            }
            .padding(18)

            Divider().overlay(AppTheme.line)

            VStack(spacing: 0) {
                settingRow("Dock Icon", isOn: $settings.showDockIcon)
                Divider().overlay(AppTheme.line)
                settingRow("Menu Bar Icon", isOn: $settings.showMenuBarIcon)
            }
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            }
            .padding(18)

            Spacer()
        }
        .frame(width: 390, height: 230)
        .background(AppTheme.background)
    }

    private func settingRow(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DemoContent.cyan)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}
