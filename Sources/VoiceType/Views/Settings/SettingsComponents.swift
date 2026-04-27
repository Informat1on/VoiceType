// SettingsComponents.swift — VoiceType
//
// Reusable presentational primitives used by SettingsView and its tab subviews.
// Extracted from SettingsView.swift (Chunk S) to keep that file under
// the file_length lint threshold and to make these components easier to
// discover and test.
//
// All components are pure: no @StateObject, no @ObservedObject, no
// AppDelegate references. They take their state via @Binding or plain
// let parameters. SettingsView wires them up to AppSettings.shared.
//
// Prototype source of truth: v1-cool-inksteel.html (lines cited per
// component). DESIGN.md § Layout / Color / Typography for tokens.

import SwiftUI

// MARK: - Row Primitives

/// Uppercase meta-label group header.
/// DESIGN.md line 180: 11/14 Medium, letter-spacing 0.08em, textMuted. 8px gap below.
struct GroupHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Typography.metaLabel)
            .tracking(Typography.metaLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textMuted)
            .padding(.bottom, Spacing.sm)  // 8px per DESIGN.md line 180
    }
}

// internal: used by HistorySection (same module)
/// Native prefs row: left label + optional subtitle, right control.
/// Min-height 40, horizontal padding lg, vertical padding md. DESIGN.md line 181.
/// Prototype: `.prefs-row { padding: 12px 0; min-height: 40px; }`
struct PrefsRow<Control: View>: View {
    let label: String
    let subtitle: String?
    let control: Control

    init(_ label: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)  // non-uppercase regular caption per FIX 8
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: Spacing.md)
            control
        }
        .padding(.horizontal, Spacing.prefsRowHorizontal)
        .padding(.vertical, Spacing.prefsRowVertical)
        .frame(minHeight: Spacing.prefsRowMinHeight)
    }
}

/// 1px divider. DESIGN.md line 182 / Palette.divider.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
    }
}

/// Vertical gap between row-groups. DESIGN.md § Spacing line 155.
struct SectionGap: View {
    var body: some View {
        Color.clear.frame(height: Spacing.sectionGap)
    }
}

/// Colored dot for permission state rows. DESIGN.md lines 256-258.
struct PermissionDot: View {
    enum DotState { case granted, denied, notRequested }
    let state: DotState

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        switch state {
        case .granted:      return Palette.success
        case .denied:       return Palette.error
        case .notRequested: return Palette.textMuted
        }
    }
}

// MARK: - Custom Segmented Control
//
// Replaces native Picker(.segmented). Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 273-287:
//   .seg { background:var(--surface-inset); border-radius:8px;
//          padding:2px; border:1px solid var(--stroke-subtle); }
//   .seg button { padding:4px 10px; font-size:12px; font-weight:500;
//                 color:var(--text-muted); border-radius:6px; transition:all 120ms; }
//   .seg button[aria-pressed="true"] { background:var(--bg-window);
//                                      color:var(--text-primary);
//                                      box-shadow:0 1px 2px rgba(0,0,0,0.12); }

// swiftlint:disable large_tuple
// Three-element named tuples are used for SegmentedControl options to carry
// (label, value, accessibilityLabel) without introducing a new public type.
// The struct is internal to this file and the 3-member shape is intentional
// (VT-REV-002: per-segment VoiceOver label differs from compact visible text).
struct SegmentedControl<T: Hashable>: View {
    /// Each option carries a visible `label` (compact, shown in UI) and an optional
    /// `accessibilityLabel` (full name read by VoiceOver).  When `accessibilityLabel`
    /// is nil the visible label is used — preserving backward compatibility for callers
    /// that do not need distinct VoiceOver text.
    let options: [(label: String, value: T, accessibilityLabel: String?)]
    @Binding var selection: T

    /// Convenience initialiser for callers that don't need per-segment VoiceOver labels.
    init(options: [(label: String, value: T)], selection: Binding<T>) {
        self.options = options.map { (label: $0.label, value: $0.value, accessibilityLabel: nil) }
        self._selection = selection
    }

    /// Full initialiser used when per-segment VoiceOver labels differ from visible text
    /// (e.g. compact "RU" visible / "Russian" announced — VT-REV-002).
    init(options: [(label: String, value: T, accessibilityLabel: String?)], selection: Binding<T>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segButton(option)
            }
        }
        // Outer container: surfaceInset bg, 8pt radius, 2px inner padding, strokeSubtle border
        .padding(2)
        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.strokeSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func segButton(_ option: (label: String, value: T, accessibilityLabel: String?)) -> some View {
        let isSelected = selection == option.value
        Button {
            selection = option.value
        } label: {
            Text(option.label)
                .font(Typography.buttonLabel)  // 12pt Medium — prototype font-size:12px weight:500
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textMuted)
                .padding(.horizontal, 10)  // prototype: padding 4px 10px
                .padding(.vertical, 4)
                // VT-REV-002: override the default VoiceOver label (which would read the
                // compact visible text, e.g. "RU") with the full language name when provided.
                .accessibilityLabel(option.accessibilityLabel ?? option.label)
                .background(
                    Group {
                        if isSelected {
                            // Selected: bg-window + subtle shadow
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.bgWindow)
                                .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.clear)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isSelected)  // transition:120ms per prototype
    }
}
// swiftlint:enable large_tuple

// MARK: - Permission Hint Panel
//
// Replaces plain PrefsRow for permission rows. Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 325-337:
//   .perm-hint { margin-top:6px; padding:10px 12px;
//                background:var(--accent-soft); border-radius:8px;
//                font-size:12px; color:var(--text-secondary);
//                display:flex; align-items:center; gap:10px;
//                border-left:2px solid var(--accent); }
//   .perm-hint.denied { background:rgba(255,122,107,0.10);
//                       border-left-color:var(--error); }
//   .perm-hint .perm-action { margin-left:auto; color:var(--accent);
//                             font-weight:500; cursor:pointer; }

struct PermHintPanel: View {
    enum PermState { case granted, denied, notRequested }
    let state: PermState
    let title: String
    let actionLabel: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {  // gap:10px per prototype
            PermissionDot(state: dotState)

            Text(title)
                .font(Typography.caption)  // 12pt — matches prototype font-size:12px
                .foregroundStyle(Palette.textSecondary)

            Spacer()

            // .perm-action: margin-left:auto; color:var(--accent); font-weight:500
            Button(action: onAction) {
                Text(actionLabel)
                    .font(Typography.buttonLabel)  // 12pt Medium — font-weight:500
                    .foregroundStyle(actionColor)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 10)   // prototype: padding 10px 12px
        .padding(.horizontal, 12)
        .background(panelBg, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .leading) {
            // 2pt left accent bar — prototype border-left:2px solid var(--accent)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(borderColor)
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.top, 6)  // prototype: margin-top:6px
    }

    private var dotState: PermissionDot.DotState {
        switch state {
        case .granted:      return .granted
        case .denied:       return .denied
        case .notRequested: return .notRequested
        }
    }

    // granted/notRequested = accentSoft; denied = error-tinted rgba(255,122,107,0.10)
    // Prototype line 336: .perm-hint.denied { background: rgba(255,122,107,0.10) }
    // Uses Color.dynamic (Tokens.swift) — no new literal color values beyond Tokens.swift pattern.
    // Light: #D95C4F@0.10 = sRGB(0.850,0.361,0.310,0.10)
    // Dark:  #FF7A6B@0.10 = sRGB(1.000,0.478,0.420,0.10)
    // swiftlint:disable inline_nscolor_rgb
    private var panelBg: Color {
        switch state {
        case .granted, .notRequested:
            return Palette.accentSoft
        case .denied:
            return Color.dynamic(
                light: NSColor(srgbRed: 0.850196, green: 0.360784, blue: 0.309804, alpha: 0.10),
                dark: NSColor(srgbRed: 1.000000, green: 0.478431, blue: 0.419608, alpha: 0.10)
            )
        }
    }
    // swiftlint:enable inline_nscolor_rgb

    private var borderColor: Color {
        switch state {
        case .granted, .notRequested: return Palette.accent
        case .denied:                 return Palette.error
        }
    }

    private var actionColor: Color {
        switch state {
        case .granted, .notRequested: return Palette.accent
        case .denied:                 return Palette.error
        }
    }
}

// MARK: - Compact Permission Row
//
// One-line row for the consolidated PERMISSIONS section in General tab.
// Happy path: dot + name + status text + "Open Privacy…" button — all on one line.
// The caller is responsible for rendering the expanded PermHintPanel below
// when the permission is denied/not-requested.

struct CompactPermissionRow: View {
    let name: String
    let state: PermHintPanel.PermState
    let onPrivacy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            PermissionDot(state: dotState)
            Text(name)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
            Text(statusLabel)
                .font(Typography.caption)
                .foregroundStyle(statusColor)
            Spacer(minLength: Spacing.sm)
            Button("Open Privacy\u{2026}", action: onPrivacy)
                .font(Typography.buttonLabel)
                .foregroundStyle(Palette.accent)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, Spacing.prefsRowHorizontal)
        .padding(.vertical, Spacing.prefsRowVertical)
        .frame(minHeight: Spacing.prefsRowMinHeight)
    }

    private var dotState: PermissionDot.DotState {
        switch state {
        case .granted:      return .granted
        case .denied:       return .denied
        case .notRequested: return .notRequested
        }
    }

    private var statusLabel: String {
        switch state {
        case .granted:      return "granted"
        case .denied:       return "not granted"
        case .notRequested: return "not requested"
        }
    }

    private var statusColor: Color {
        switch state {
        case .granted:      return Palette.success
        case .denied:       return Palette.error
        case .notRequested: return Palette.textMuted
        }
    }
}

// MARK: - Sidebar Item
//
// Replaces NavigationSplitView List rows. Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 227-243:
//   .sidebar-item { display:flex; align-items:center; gap:8px;
//                   padding:6px 10px; border-radius:6px;
//                   font-size:13px; color:var(--text-secondary);
//                   transition:background-color 120ms; }
//   .sidebar-item:hover { background:var(--sidebar-hover); }
//   .sidebar-item.active { background:var(--sidebar-active);
//                          color:var(--text-primary); font-weight:500; }
//   .sidebar-item.active::before { content:""; width:2px; height:16px;
//                                  background:var(--accent); border-radius:1px;
//                                  margin-left:-10px; margin-right:4px; }

struct SidebarItem: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                // Active indicator bar — CSS ::before pseudo-element equivalent.
                // width:2px; height:16px; accent color; border-radius:1px;
                // Offset to leading edge of padding zone.
                if isActive {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Palette.accent)
                        .frame(width: 2, height: 16)
                        .offset(x: -6)
                        .padding(.trailing, -2)
                } else {
                    Color.clear.frame(width: 2, height: 16)
                        .offset(x: -6)
                        .padding(.trailing, -2)
                }

                HStack(alignment: .center, spacing: 8) {  // gap:8px per prototype
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 14, height: 14)  // svg 14x14 per prototype line 243
                        .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)

                    Text(label)
                        .font(isActive
                              ? Font.custom("Geist", size: 13).weight(.medium)  // font-weight:500
                              : Typography.body)
                        .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)

                    Spacer()
                }
            }
            .padding(.horizontal, 10)  // prototype: padding:6px 10px
            .padding(.vertical, 6)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.sidebarActive)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.sidebarHover)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                    }
                }
            )
            .animation(.easeInOut(duration: 0.12), value: isActive)   // transition:120ms
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
    }
}

// MARK: - Model Row
//
// Extracted from SettingsView.swift (Chunk T). Represents one selectable
// model in the Models tab list. Module-internal (was private in SettingsView).

struct ModelRow: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let onSelect: () -> Void
    /// Live model status — only relevant for the active (selected) row.
    /// Pass `.notLoaded` for non-selected rows. Exposed as a plain `let` so
    /// SettingsView can forward the published value without giving ModelRow
    /// an @ObservedObject reference to TranscriptionService.
    var activeModelStatus: ModelStatus = .notLoaded
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        let compatible = model.isCompatibleWithCurrentEngine
        Button(action: compatible ? onSelect : {}) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textMuted)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    // For the active (selected) model, show the live model status dot
                    // next to the display name so users can see load state from Settings.
                    HStack(spacing: 5) {
                        Text(model.displayName)
                            .font(Typography.body)
                            .foregroundStyle(compatible ? Palette.textPrimary : Palette.textMuted)
                        if isSelected {
                            Circle()
                                .fill(activeModelStatusDotColor)
                                .frame(width: 9, height: 9)
                                .accessibilityLabel(activeModelStatusAccessibilityLabel)
                                .help(activeModelStatusTooltip)
                        }
                    }
                    Text("\(model.estimatedSize) · Speed \(model.speedRating) · Quality \(model.qualityRating)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(model.recommendedFor)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                }

                Spacer(minLength: Spacing.md)

                downloadStateBadge
            }
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.vertical, Spacing.prefsRowVertical)
            .frame(minHeight: Spacing.prefsRowMinHeight)
            .opacity(compatible ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(!compatible)
        .accessibilityLabel(model.displayName)
        .accessibilityValue("\(downloadStateAccessibilityValue), \(model.estimatedSize), Speed \(model.speedRating), Quality \(model.qualityRating)")
    }

    @ViewBuilder
    private var downloadStateBadge: some View {
        if !model.isCompatibleWithCurrentEngine {
            StatusBadge("Requires update", tone: .warning)
        } else if modelManager.isModelDownloaded(model: model) {
            StatusBadge("Downloaded", tone: .positive)
        } else {
            StatusBadge("Not downloaded")
        }
    }

    private var downloadStateAccessibilityValue: String {
        if !model.isCompatibleWithCurrentEngine { return "Requires engine update, not selectable" }
        return modelManager.isModelDownloaded(model: model) ? "Downloaded" : "Not downloaded"
    }

    // MARK: Active model status dot helpers (isSelected rows only)

    /// Dot color mirroring the MenuBarView model status palette tokens.
    private var activeModelStatusDotColor: Color {
        switch activeModelStatus {
        case .ready:                return Palette.success
        case .loading, .warming:    return Palette.warning
        case .error:                return Palette.error
        case .notLoaded:            return Palette.textMuted
        }
    }

    private var activeModelStatusAccessibilityLabel: String {
        switch activeModelStatus {
        case .ready:     return "Model ready"
        case .loading:   return "Model loading"
        case .warming:   return "Model warming up"
        case .error:     return "Model error"
        case .notLoaded: return "Model not loaded"
        }
    }

    /// Tooltip for the status dot — shows error message for .error, empty otherwise.
    private var activeModelStatusTooltip: String {
        if case .error(let msg) = activeModelStatus { return msg }
        return activeModelStatusAccessibilityLabel
    }
}
