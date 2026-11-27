import SwiftUI
import AppKit
import NXCore
import NXModel

package struct AppleTVCard: View {
    @ObservedObject var devices: DeviceStore
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @Environment(\.launcherSectionTitleFont) private var titleFont
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsText = ""
    @State private var settingsGame = ""
    let showLocked: Bool

    private static let blockingProblems: Set<String> = ["tv.nxnativeOnly", "tv.noSDK", "tv.pairDevice"]

    package init(devices: DeviceStore, build: BuildStore, showLocked: Bool = true) {
        self.devices = devices
        self.build = build
        self.showLocked = showLocked
    }

    package var body: some View {
        if build.target == BuildTarget.tvos, !build.running || showLocked {
            content
                .disabled(build.running)
                .onAppear(perform: appeared)
                .onChange(of: build.buildKey) { _ in loadSettings() }
                .onChange(of: settingsText) { text in build.setAppleTVSettings(text, forGame: settingsGame) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("tv.section")).font(titleFont).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
            CardGroup("") {
                deviceSection.padding(18)
                if devices.appleTVs.contains(where: { $0.id == devices.appleTVDevice }) {
                    CardDivider()
                    teamRow
                }
                CardDivider()
                settingsSection.padding(18)
            }
        }
    }

    private var blockingProblem: String? {
        build.appleTVProblemKey.flatMap { Self.blockingProblems.contains($0) ? $0 : nil }
    }

    private var deviceNotice: String? {
        build.appleTVProblemKey.flatMap { Self.blockingProblems.contains($0) || $0 == "tv.needsTeam" ? nil : $0 }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(loc.t("flow.chooseDevice")).font(.manrope(16, .semibold))
                Spacer()
                RefreshDevicesButton(checked: devices.appleTVsChecked, padID: "set.build.tv.refresh") { _ = devices.refreshAppleTVs() }
            }
            deviceList
        }
    }

    @ViewBuilder private var deviceList: some View {
        if !devices.appleTVsChecked {
            Text(loc.t("tv.looking")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
        } else if let blockingProblem {
            unavailable(blockingProblem)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(devices.appleTVs) { deviceTile($0) }
            }
            if let deviceNotice {
                Text(loc.t(deviceNotice)).font(DS.Font.callout).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unavailable(_ key: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv").font(.system(size: 28)).accessibilityHidden(true)
            Text(loc.t(key)).font(DS.Font.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if key != "tv.nxnativeOnly" {
                Button(loc.t("flow.openXcode")) { XcodeLauncher.open() }
                    .padTarget("set.build.tv.xcode", scope: "main", activate: { XcodeLauncher.open() })
            }
        }.frame(maxWidth: .infinity).padding(20)
    }

    private func deviceTile(_ device: AppleDevice) -> some View {
        let selected = devices.appleTVDevice == device.id
        return Button { devices.appleTVDevice = device.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Image(systemName: "appletv").font(.system(size: 24))
                }
                Spacer(minLength: 0)
                Text(device.name).font(DS.Font.bodyStrong).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(device.model).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            }.padding(16).frame(height: 136, alignment: .topLeading)
                .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .padTarget("set.build.tv.device." + device.id, scope: "main", radius: 14, enabled: !build.running) { devices.appleTVDevice = device.id }
    }

    private func stepTeam(_ by: Int, options: [(value: String, label: String)]) {
        if !build.running { devices.stepSigningTeam(by, options: options) }
    }

    @ViewBuilder private var teamRow: some View {
        let teams = devices.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        if teams.isEmpty {
            CardRow(loc.t("dev.team"), detail: loc.t("flow.signingRequired"), dot: LauncherPalette.building) { EmptyView() }
        } else {
            CardRow(loc.t("dev.team"), detail: loc.t("tv.teamNote")) {
                LauncherDropdown(options: teams, selection: devices.signingTeam, label: loc.t("dev.team")) { devices.signingTeam = $0 }
                    .padTarget("set.build.tv.team", scope: "main", enabled: !build.running, activate: { stepTeam(1, options: teams) }, adjust: { stepTeam($0, options: teams) })
            }
        }
    }

    @ViewBuilder private var ignoredSettingsHint: some View {
        let ignored = AppleTVBuild.ignoredSettingsLines(settingsText)
        if !ignored.isEmpty {
            Text(String(format: loc.t("tv.settingsIgnored"), ignored.joined(separator: ", ")))
                .font(DS.Font.callout).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("tv.settings")).font(.manrope(14))
            Text(loc.t("tv.settingsNote")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $settingsText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 72, maxHeight: 140)
                .background(LauncherPalette.well, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(loc.t("tv.settings"))
            ignoredSettingsHint
        }
    }

    private func loadSettings() {
        settingsGame = build.buildKey
        settingsText = build.appleTVSettings(forGame: settingsGame)
    }

    private func appeared() {
        loadSettings()
        devices.refreshAppleTVs()
    }
}
