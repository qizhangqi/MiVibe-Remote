import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import RemoteMic

/// BridgeAppModel reads and writes UserDefaults.standard (the test runner's own
/// domain). Put back every settings key a test touched.
private func withRestoredStandardDefaults(_ body: () throws -> Void) rethrows {
    let keys = [
        "gainDB", "selectedAudioDeviceUID", "customMappingEnabled", "exclusiveHID",
        "buttonBindings", "buttonShortcuts", "secondaryButtonBindings",
        "voiceShortcutProfile", "customVoiceShortcut", "customVoiceTriggerMode",
        "customPresetBindings", "customPresetShortcuts", "customPresetSecondaryBindings",
        "localPresets", "activeLocalPresetID", "headsetCompatibilityEnabled",
        "computerMicrophonePassthroughEnabled",
    ]
    let defaults = UserDefaults.standard
    let saved = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    try body()
}

/// Set from Observation's onChange, which may run on any thread.
private final class Flag: @unchecked Sendable {
    var isSet = false
}

@MainActor
private func pumpMainRunLoop(_ seconds: Double = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func allSubviews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allSubviews)
}

/// The settings window, built off screen (never shown).
@MainActor
private final class OffscreenSettingsWindow {
    let model: BridgeAppModel
    let window: NSWindow
    let hosting: NSView

    init(model: BridgeAppModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: SettingsView(model: model))
        window.contentView = hosting
        settle()
    }

    func settle() {
        hosting.layoutSubtreeIfNeeded()
        pumpMainRunLoop(0.05)
        hosting.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// The 12 mapping-row popups in RemoteButton.allCases order: two columns of
    /// six, each 112 pt wide; columns left to right, rows top to bottom.
    func rowPopups() -> [NSPopUpButton] {
        let popups = allSubviews(hosting).compactMap { $0 as? NSPopUpButton }
            .filter { abs($0.frame.width - 112) < 1 }
        let columns = Dictionary(grouping: popups) {
            Int($0.convert($0.bounds, to: nil).minX.rounded())
        }
        .filter { $0.value.count == 6 }
        .sorted { $0.key < $1.key }
        guard columns.count == 2 else { return [] }
        return columns.flatMap { column in
            column.value.sorted {
                $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
            }
        }
    }

    /// Buttons whose popup does not show the current setting.
    func staleRows() -> [RemoteButton] {
        let installed = PresetApplication.installedBundleIdentifiers
        let popups = rowPopups()
        guard popups.count == RemoteButton.allCases.count else { return RemoteButton.allCases }
        return zip(RemoteButton.allCases, popups).compactMap { button, popup in
            let action = model.settings.action(for: button)
            let unavailable = action.presetApplication.map {
                !installed.contains($0.bundleIdentifier)
            } ?? false
            let expected = action.displayName + (unavailable ? "（未安装）" : "")
            return popup.titleOfSelectedItem == expected ? nil : button
        }
    }
}

@Suite("Settings window updates", .serialized)
@MainActor
struct SettingsWindowUpdateTests {
    @Test func voiceShortcutStatusShowsTheProfileJustSelected() {
        withRestoredStandardDefaults {
            let model = BridgeAppModel()
            model.settings.selectVoiceShortcutProfile(.codex)
            pumpMainRunLoop()
            for profile in [VoiceShortcutProfile.workBuddy, .weChat, .codex] {
                model.settings.selectVoiceShortcutProfile(profile)
                pumpMainRunLoop()
                #expect(model.voiceShortcutStatus == profile.readyStatus)
            }
        }
    }

    @Test func everyRowShowsTheCurrentMappingAfterChanges() throws {
        try withRestoredStandardDefaults {
            let model = BridgeAppModel()
            model.settings.customMappingEnabled = true
            model.settings.applyWeChatPreset()
            let window = OffscreenSettingsWindow(model: model)
            defer { window.close() }
            #expect(window.rowPopups().count == 12)
            #expect(window.staleRows() == [])

            // One row, set in code.
            model.settings.setAction(.arrowUp, for: .ok)
            window.settle()
            #expect(window.staleRows() == [])

            // Every row at once.
            model.settings.applyCodexPreset()
            window.settle()
            #expect(window.staleRows() == [])
            model.settings.resetBindings()
            window.settle()
            #expect(window.staleRows() == [])

            // A click on a menu item writes the setting, and the row shows it.
            let popup = try #require(window.rowPopups().dropFirst().first) // .up
            let next = popup.indexOfSelectedItem == 1 ? 2 : 1
            let expected = ButtonAction.pickerActions(
                installedBundleIdentifiers: PresetApplication.installedBundleIdentifiers,
                current: model.settings.action(for: .up)
            )[next]
            popup.menu?.performActionForItem(at: next)
            window.settle()
            #expect(model.settings.action(for: .up) == expected)
            #expect(window.staleRows() == [])
        }
    }

    @Test func movingTheSelectionKeepsEveryRowsPopup() throws {
        try withRestoredStandardDefaults {
            let model = BridgeAppModel()
            model.settings.customMappingEnabled = true
            model.settings.applyWeChatPreset()
            let window = OffscreenSettingsWindow(model: model)
            defer { window.close() }
            let before = window.rowPopups()
            #expect(before.count == 12)

            // .ok is selected; picking in the .up row selects .up instead.
            let upRow = try #require(before.dropFirst().first)
            upRow.menu?.performActionForItem(at: upRow.indexOfSelectedItem == 1 ? 2 : 1)
            window.settle()

            // Same NSPopUpButton objects: no row was rebuilt for the selection.
            let after = window.rowPopups()
            #expect(after.count == 12)
            #expect(zip(before, after).allSatisfy { $0 === $1 })
            #expect(window.staleRows() == [])
        }
    }

    @Test func secondaryAndVoicePickersFollowSelectionAndSettings() throws {
        try withRestoredStandardDefaults {
            let model = BridgeAppModel()
            let settings = model.settings
            settings.customMappingEnabled = true
            settings.applyWeChatPreset()
            settings.setAction(.arrowUp, for: .up, trigger: .doubleClick)
            let window = OffscreenSettingsWindow(model: model)
            defer { window.close() }
            @MainActor func popups(width: CGFloat) -> [NSPopUpButton] {
                allSubviews(window.hosting).compactMap { $0 as? NSPopUpButton }
                    .filter { abs($0.frame.width - width) < 1 }
                    .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            }
            @MainActor func doubleClickTitle() -> String? { popups(width: 150).first?.titleOfSelectedItem }

            // .ok is selected at first and has no double-click action.
            #expect(doubleClickTitle() == ButtonAction.disabled.displayName)

            // Picking in the .up row selects .up; the panel follows the selection.
            let upRow = try #require(window.rowPopups().dropFirst().first)
            upRow.menu?.performActionForItem(at: upRow.indexOfSelectedItem == 1 ? 2 : 1)
            window.settle()
            #expect(doubleClickTitle() == ButtonAction.arrowUp.displayName)

            // A change made in code shows up too.
            settings.setAction(.arrowDown, for: .up, trigger: .doubleClick)
            window.settle()
            #expect(doubleClickTitle() == ButtonAction.arrowDown.displayName)

            // The voice shortcut picker follows the selected profile.
            let profileNames = Set(VoiceShortcutProfile.allCases.map(\.displayName))
            @MainActor func voicePicker() -> NSPopUpButton? {
                allSubviews(window.hosting).compactMap { $0 as? NSPopUpButton }
                    .first { Set($0.itemTitles) == profileNames }
            }
            for profile in [VoiceShortcutProfile.workBuddy, .codex, .weChat] {
                settings.selectVoiceShortcutProfile(profile)
                window.settle()
                #expect(voicePicker()?.titleOfSelectedItem == profile.displayName)
            }
        }
    }

    @Test func aMappingChangeOnlyNotifiesViewsThatReadMappings() {
        withRestoredStandardDefaults {
            let model = BridgeAppModel()
            let settings = model.settings
            let gainReader = Flag(), mappingReader = Flag(), statusReader = Flag()
            withObservationTracking { _ = settings.gainDB } onChange: { gainReader.isSet = true }
            withObservationTracking { _ = settings.action(for: .ok) } onChange: { mappingReader.isSet = true }
            withObservationTracking { _ = model.hidStatus } onChange: { statusReader.isSet = true }

            settings.setAction(settings.action(for: .ok) == .arrowUp ? .returnKey : .arrowUp, for: .ok)

            #expect(mappingReader.isSet)
            #expect(!gainReader.isSet)
            #expect(!statusReader.isSet)
        }
    }

    @Test func observationLoopRunsAgainWithTheNewValue() {
        withRestoredStandardDefaults {
            let settings = AppSettings(defaults: UserDefaults(suiteName: "RemoteMicTests.observationLoop")!)
            defer { UserDefaults().removePersistentDomain(forName: "RemoteMicTests.observationLoop") }
            var seen: [Double] = []
            ObservationLoop.run { seen.append(settings.gainDB) }
            settings.gainDB = 7
            settings.gainDB = 9 // two changes in one turn of the run loop: one re-run
            pumpMainRunLoop()
            settings.gainDB = 11
            pumpMainRunLoop()
            #expect(seen.count == 3)
            #expect(seen.dropFirst() == [9, 11])
        }
    }
}
