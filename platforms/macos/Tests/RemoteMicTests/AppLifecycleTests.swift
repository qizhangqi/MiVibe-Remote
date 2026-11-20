import AppKit
import Foundation
import Testing

@Suite("App lifecycle")
struct AppLifecycleTests {
    @Test func regularAppHasFastNavigationReopenAndClearExitPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let infoPlist = try String(
            contentsOf: root.appendingPathComponent("Resources/Info.plist"),
            encoding: .utf8
        )

        #expect(appSource.contains("configureMainMenu()"))
        #expect(appSource.contains("appUpdater = AppUpdater()"))
        #expect(appSource.contains("appUpdater?.start()"))
        #expect(appSource.contains("menu.addItem(updateMenuItem())"))
        #expect(appSource.contains("applicationMenu.addItem(updateMenuItem())"))
        #expect(appSource.contains("检查更新…（自动更新未配置）"))
        #expect(appSource.contains("title: \"退出 MiVibe Remote\""))
        #expect(appSource.contains("keyEquivalent: \"q\""))
        #expect(appSource.contains("application.setActivationPolicy(.regular)"))
        #expect(appSource.contains("applicationShouldHandleReopen"))
        #expect(appSource.contains("refreshMenuStatus()\n        showSettings()"))
        #expect(appSource.contains("styleMask: [.titled, .closable, .resizable]"))
        #expect(!appSource.contains(".miniaturizable"))
        #expect(settingsSource.contains("Text(\"退出应用\")"))
        #expect(settingsSource.contains("NSApp.terminate(nil)"))
        #expect(!settingsSource.contains("NavigationSplitView"))
        #expect(!settingsSource.contains("settings-navigation-selection"))
        #expect(settingsSource.contains("ZStack"))
        #expect(settingsSource.contains(".allowsHitTesting(selectedSection =="))
        #expect(settingsSource.contains("SettingsSection.mainFlow"))
        #expect(settingsSource.contains("case guide"))
        #expect(settingsSource.contains("title: \"使用教程\""))
        #expect(settingsSource.contains("Text(\"语音键动作\")"))
        #expect(settingsSource.contains("TextField(\"输入预设名称\""))
        #expect(settingsSource.contains("help(\"新增自定义预设\")"))
        #expect(settingsSource.contains("再次点击可重命名"))
        #expect(settingsSource.contains("pendingPresetDeletion = preset"))
        #expect(settingsSource.contains("删除自定义预设"))
        #expect(settingsSource.contains("Button(\"确定\")"))
        #expect(settingsSource.contains("confirmCustomVoiceEditing()"))
        #expect(settingsSource.contains("overwriteLocalPresetWithCurrentSettings"))
        #expect(settingsSource.contains("matching: [.keyDown, .flagsChanged]"))
        #expect(settingsSource.contains("也可以单独录入"))
        #expect(!settingsSource.contains("Label(\"保存为新预设\""))
        #expect(settingsSource.contains("sidebarButton(.about, subtitle: \"起司制作\")"))
        #expect(settingsSource.contains("publisher(for: .showRemoteMicAbout)"))
        #expect(appSource.contains("NotificationCenter.default.post(name: .showRemoteMicAbout"))
        #expect(!appSource.contains("orderFrontStandardAboutPanel"))
        #expect(appSource.contains("model.recoverHIDSettingsAfterActivation()"))
        #expect(infoPlist.contains("<key>LSUIElement</key>"))
        #expect(infoPlist.contains("<false/>"))
    }

    @Test func settingsWindowIsRebuiltOnOpenAndKeepsItsSavedPosition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // Closing releases the window; the next open builds a new one.
        #expect(appSource.contains("settingsWindowController = nil"))
        #expect(appSource.contains(
            "settingsWindowController = makeSettingsWindowController(showingAbout: showingAbout)"
        ))
        // The rebuilt window is centered first, then the autosave name restores
        // the saved frame (see windowFrameAutosaveOnlyWinsWhenSetAfterCentering).
        let center = try #require(appSource.range(of: "window.center()"))
        let autosave = try #require(appSource.range(of: "window.setFrameAutosaveName(\"RemoteMicSettings\")"))
        #expect(center.upperBound <= autosave.lowerBound)
        // "About" opens on the About page, even when the window was closed.
        #expect(appSource.contains("showSettingsWindow(showingAbout: true)"))
        #expect(appSource.contains("showsAboutInitially: showingAbout"))
        #expect(settingsSource.contains("showsAboutInitially ? .about : .connection"))
    }

    @MainActor
    @Test func windowFrameAutosaveOnlyWinsWhenSetAfterCentering() throws {
        let name = "RemoteMicTests.settingsFrame.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        func makeWindow(centerBeforeAutosave: Bool) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            if centerBeforeAutosave {
                window.center()
                window.setFrameAutosaveName(name)
            } else {
                window.setFrameAutosaveName(name)
                window.center()
            }
            return window
        }
        // The user moved the first window; AppKit saved its frame. Keep it on
        // the display the window opened on: a frame saved on another display
        // is mapped to the same relative position on the current one.
        let first = makeWindow(centerBeforeAutosave: true)
        let visible = try #require(first.screen, "needs a display").visibleFrame
        let movedOrigin = NSPoint(x: visible.minX + 37, y: visible.minY + 41)
        first.setFrameOrigin(movedOrigin)
        first.saveFrame(usingName: name)
        let savedFrame = first.frame
        first.setFrameAutosaveName("")
        first.close()

        let reopened = makeWindow(centerBeforeAutosave: true)
        #expect(reopened.frame == savedFrame)
        reopened.setFrameAutosaveName("")
        reopened.close()

        let centeredLast = makeWindow(centerBeforeAutosave: false)
        #expect(centeredLast.frame.origin != movedOrigin)
        centeredLast.setFrameAutosaveName("")
        centeredLast.close()
    }
}
