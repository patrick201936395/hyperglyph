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
            hudSection
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

    // MARK: - Pop-up (HUD) appearance

    private var hudSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Position")
                    .font(.subheadline.weight(.medium))
                HUDPositionPicker(selection: configBinding(\.hudPosition))
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Design")
                    .font(.subheadline.weight(.medium))
                HUDTemplatePicker(selection: configBinding(\.hudTemplate))
            }
            .padding(.vertical, 4)

            Button {
                coordinator.hud.showPreview()
            } label: {
                Label("Preview Pop-up", systemImage: "eye")
            }
            .disabled(!coordinator.config.hudEnabled)
        } header: {
            Text("Gesture Pop-up")
        } footer: {
            Text("Where and how the pop-up appears when a gesture fires. Preview shows it live with the current settings.")
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

// MARK: - HUD position picker

/// A miniature screen with clickable anchor dots for choosing where the
/// gesture pop-up appears.
private struct HUDPositionPicker: View {
    @Binding var selection: HUDPosition

    private static let screenSize = CGSize(width: 220, height: 138)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quinary)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
            // Menu bar hint line.
            VStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(height: 5)
                    .padding(.horizontal, 5)
                    .padding(.top, 5)
                Spacer()
            }

            ForEach(HUDPosition.allCases) { position in
                anchorDot(position)
            }
        }
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
    }

    private func anchorDot(_ position: HUDPosition) -> some View {
        let anchor = position.anchor
        let isSelected = selection == position
        // anchor.y is y-up; SwiftUI y is down.
        let x = Self.screenSize.width * anchor.x
        let y = Self.screenSize.height * (1 - anchor.y)

        return Button {
            selection = position
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: isSelected ? 22 : 16, height: isSelected ? 22 : 16)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .position(x: x, y: y)
        .help(position.displayName)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selection)
    }
}

// MARK: - HUD template picker

/// Gallery of pop-up designs, each rendered as a live miniature.
private struct HUDTemplatePicker: View {
    @Binding var selection: HUDTemplate

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HUDTemplate.allCases) { template in
                templateCard(template)
            }
        }
    }

    private func templateCard(_ template: HUDTemplate) -> some View {
        let isSelected = selection == template
        return Button {
            selection = template
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                    TemplateMiniature(template: template)
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                            lineWidth: isSelected ? 2 : 1
                        )
                )

                Text(template.displayName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(template.displayName)
    }
}

/// Tiny non-interactive mock of each pop-up design for the gallery cards.
private struct TemplateMiniature: View {
    var template: HUDTemplate

    var body: some View {
        switch template {
        case .glass:
            HStack(spacing: 4) {
                miniGlyph(diameter: 16)
                miniIcon(side: 13)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)

        case .midnight:
            HStack(spacing: 4) {
                miniGlyph(diameter: 16)
                miniIcon(side: 13)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.88)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.green.opacity(0.4), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)

        case .minimal:
            HStack(spacing: 3) {
                Text("C").font(.system(size: 7, weight: .bold, design: .rounded))
                miniIcon(side: 9)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)

        case .jumbo:
            VStack(spacing: 3) {
                miniGlyph(diameter: 17)
                miniIcon(side: 12)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .environment(\.colorScheme, .dark)
        }
    }

    private func miniGlyph(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(.green.opacity(0.16))
            Circle().strokeBorder(.green.opacity(0.55), lineWidth: 0.8)
            Text("C").font(.system(size: diameter * 0.5, weight: .bold, design: .rounded))
        }
        .frame(width: diameter, height: diameter)
    }

    private func miniIcon(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: side * 0.24)
            .fill(
                LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: side, height: side)
    }
}
