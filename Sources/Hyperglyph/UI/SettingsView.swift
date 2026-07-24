import ServiceManagement
import SwiftUI
import HyperglyphKit

/// The Settings page: general toggles, feedback options, gesture tuning
/// sliders, permission status, and a destructive reset — all persisted live
/// through `AppCoordinator.config`.
struct SettingsView: View {
    var coordinator: AppCoordinator

    @State private var launchAtLogin = false
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            generalSection
            feedbackSection
            tuningSection
            permissionsSection
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
        }
        .task {
            // Keep the permission row live while Settings is visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
            }
        }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) {
                resetAllSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All gesture bindings, custom shapes, and tuning values will be restored to their defaults. This cannot be undone.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Enable Hyperglyph", isOn: masterEnabledBinding)
            Toggle("Launch at Login", isOn: launchAtLoginBinding)
        } header: {
            Text("General")
        } footer: {
            Text("When disabled, no taps or shapes are detected and the trackpad behaves normally.")
        }
    }

    private var masterEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.state.isEnabled },
            set: { coordinator.setEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        if enable {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        // Reflect what actually happened, not what was requested.
        launchAtLogin = SMAppService.mainApp.status == .enabled
        coordinator.config.launchAtLogin = launchAtLogin
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section {
            Toggle("Trackpad Haptics", isOn: configBinding(\.hapticsEnabled))
            Toggle("Show HUD Overlay", isOn: configBinding(\.hudEnabled))
        } header: {
            Text("Feedback")
        } footer: {
            Text(
                coordinator.state.hapticsUsingPrivateAPI
                    ? "Using native trackpad actuator"
                    : "Using system fallback haptics"
            )
        }
    }

    // MARK: - Gesture tuning

    private var tuningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Instant Draw", isOn: configBinding(\.instantDraw))
                    .toggleStyle(.switch)
                Text("Just draw with two fingers — no need to hold still first. Scrolls stay silent; only recognized shapes fire. Turn off to require a brief two-finger hold (with a haptic tick) before drawing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !coordinator.config.instantDraw {
                tuningSlider(
                    "Draw Arm Delay",
                    value: configBinding(\.dwellSeconds),
                    in: 0.05...0.40,
                    display: "\(Int((coordinator.config.dwellSeconds * 1000).rounded())) ms",
                    footnote: "How long two fingers must rest still before shape drawing arms. Shorter feels snappier; longer avoids arming during scrolls."
                )
                tuningSlider(
                    "Stillness Tolerance",
                    value: configBinding(\.stillnessThreshold),
                    in: 0.005...0.04,
                    display: String(format: "%.3f", coordinator.config.stillnessThreshold),
                    footnote: "How much the fingers may drift while dwelling and still count as holding still. Raise this if drawing is hard to arm."
                )
            }
            tuningSlider(
                "Tap Max Duration",
                value: configBinding(\.tapMaxDuration),
                in: 0.10...0.50,
                display: String(format: "%.2f s", coordinator.config.tapMaxDuration),
                footnote: "Touches longer than this no longer count as a zone tap."
            )
            tuningSlider(
                "Multi-Tap Window",
                value: configBinding(\.multiTapWindow),
                in: 0.20...0.60,
                display: String(format: "%.2f s", coordinator.config.multiTapWindow),
                footnote: "How long Hyperglyph waits for another tap before firing a single, double, or triple tap."
            )
            tuningSlider(
                "Shape Match Strictness",
                value: configBinding(\.matchThreshold),
                in: 0.50...0.95,
                display: "\(Int((coordinator.config.matchThreshold * 100).rounded()))%",
                footnote: "Minimum recognizer score for a drawn shape to match. Higher means fewer false matches but sloppier strokes are rejected."
            )
        } header: {
            Text("Gesture Tuning")
        }
    }

    private func tuningSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: String,
        footnote: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(display)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: coordinator.state.accessibilityGranted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(coordinator.state.accessibilityGranted ? .green : .orange)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text(coordinator.state.accessibilityGranted
                        ? "Granted — keyboard shortcuts and scroll blocking are available."
                        : "Required for keyboard shortcuts and scroll blocking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !coordinator.state.accessibilityGranted {
                    Button("Grant…") {
                        ActionRunner.requestAccessibility()
                        coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Permissions")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            Button("Reset All Settings…", role: .destructive) {
                showingResetConfirmation = true
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Restores default bindings, shapes, and tuning. Login item registration is not affected.")
        }
    }

    private func resetAllSettings() {
        coordinator.config = ConfigStore.defaultConfig()
        // Keep the live master switch in sync with the freshly reset config.
        coordinator.setEnabled(coordinator.config.isEnabled)
    }

    // MARK: - Bindings

    /// A binding into `coordinator.config`; writes flow through the
    /// coordinator's `didSet`, which persists and applies the change live.
    private func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.config[keyPath: keyPath] },
            set: { coordinator.config[keyPath: keyPath] = $0 }
        )
    }
}
