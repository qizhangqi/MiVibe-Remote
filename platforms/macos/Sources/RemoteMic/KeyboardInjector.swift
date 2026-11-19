import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = (
        URL,
        PresetApplication,
        @escaping (Error?) -> Void
    ) -> Void
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void
    typealias KeyStatePoster = (CGKeyCode, CGEventFlags, Bool) -> Bool
    typealias KeyTapPoster = (CGKeyCode, CGEventFlags) -> Bool
    typealias ScrollPoster = (Int32) -> Void

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let contextualMenuKeyCode: CGKeyCode = 110
    static let codexDictationKeyCode: CGKeyCode = 2
    static let codexDictationFlags: CGEventFlags = [.maskControl, .maskShift]
    static let workBuddyVoiceKeyCode: CGKeyCode = 2
    static let workBuddyVoiceFlags: CGEventFlags = [.maskCommand]
    static let scrollWheelStep: Int32 = 3
    /// WeChat 4.x exposes “语音输入文字（按住 Fn）”. Fn is a modifier and must
    /// be posted as flags-changed state, not as a normal microphone-key tap.
    static let weChatFunctionKeyCode: CGKeyCode = 63
    private static let eventSource = CGEventSource(stateID: .hidSystemState)

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func setCodexDictationHeld(
        _ held: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: (CGKeyCode, CGEventFlags, Bool) -> Bool = {
            postKeyState(code: $0, flags: $1, isDown: $2)
        }
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        return keyStatePoster(codexDictationKeyCode, codexDictationFlags, held)
    }

    @discardableResult
    static func sendVoiceShortcut(
        profile: VoiceShortcutProfile,
        transition: VoiceFunctionKeyTransition,
        customShortcut: CustomKeyboardShortcut? = nil,
        customTriggerMode: VoiceShortcutTriggerMode = .hold,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: (CGKeyCode, CGEventFlags, Bool) -> Bool = {
            postKeyState(code: $0, flags: $1, isDown: $2)
        },
        functionKeyStatePoster: (Bool) -> Bool = {
            postFunctionKeyState(isDown: $0)
        },
        keyTapPoster: (CGKeyCode, CGEventFlags) -> Bool = {
            postKeyPress(code: $0, flags: $1)
        },
        modifierKeyStatePoster: KeyStatePoster = {
            postModifierKeyState(code: $0, flags: $1, isDown: $2)
        },
        modifierKeyTapPoster: KeyTapPoster = {
            postModifierKeyPress(code: $0, flags: $1)
        }
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        switch profile {
        case .codex:
            return keyStatePoster(
                codexDictationKeyCode,
                codexDictationFlags,
                transition == .press
            )
        case .workBuddy:
            return keyTapPoster(workBuddyVoiceKeyCode, workBuddyVoiceFlags)
        case .weChat:
            return functionKeyStatePoster(transition == .press)
        case .custom:
            guard let customShortcut else { return false }
            if customShortcut.isStandaloneModifier {
                switch customTriggerMode {
                case .hold:
                    return modifierKeyStatePoster(
                        CGKeyCode(customShortcut.keyCode),
                        customShortcut.cgEventFlags,
                        transition == .press
                    )
                case .toggle:
                    return modifierKeyTapPoster(
                        CGKeyCode(customShortcut.keyCode),
                        customShortcut.cgEventFlags
                    )
                }
            }
            switch customTriggerMode {
            case .hold:
                return keyStatePoster(
                    CGKeyCode(customShortcut.keyCode),
                    customShortcut.cgEventFlags,
                    transition == .press
                )
            case .toggle:
                return keyTapPoster(
                    CGKeyCode(customShortcut.keyCode),
                    customShortcut.cgEventFlags
                )
            }
        }
    }

    @discardableResult
    static func sendVoiceShortcut(
        configuration: VoiceShortcutConfiguration,
        transition: VoiceFunctionKeyTransition
    ) -> Bool {
        sendVoiceShortcut(
            profile: configuration.profile,
            transition: transition,
            customShortcut: configuration.customShortcut,
            customTriggerMode: configuration.customTriggerMode
        )
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) },
        frontmostKeyPoster: KeyPoster = {
            postKeyToFrontmostApplication(code: $0, flags: $1)
        },
        modifierKeyTapPoster: KeyPoster = {
            _ = postModifierKeyPress(code: $0, flags: $1)
        },
        scrollPoster: ScrollPoster = {
            postScrollWheel(delta: $0)
        }
    ) -> Bool {
        guard action != .disabled else { return true }
        if let application = action.presetApplication {
            open(
                application,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener
            )
            return true
        }
        if action == .customShortcut, shortcut == nil {
            AppLogger.shared.write("SHORTCUT ACTION ignored reason=not_configured")
            return true
        }
        guard accessibilityTrusted() else { return false }

        switch action {
        case .disabled:
            return true
        case .escape:
            keyPoster(53, [])
        case .returnKey:
            keyPoster(36, [])
        case .arrowUp:
            keyPoster(126, [])
        case .arrowDown:
            keyPoster(125, [])
        case .arrowLeft:
            keyPoster(123, [])
        case .arrowRight:
            keyPoster(124, [])
        case .scrollUp:
            scrollPoster(scrollWheelStep)
        case .scrollDown:
            scrollPoster(-scrollWheelStep)
        case .deleteBackward:
            // Back arrives through MiVibe rather than the native keyboard
            // stack. Posting directly to the foreground process avoids the
            // extra global CGEvent queue that makes consecutive deletes lag.
            frontmostKeyPoster(51, [])
        case .showDesktop:
            keyPoster(103, .maskSecondaryFn)
        case .contextMenu:
            keyPoster(contextualMenuKeyCode, [])
        case .appSwitcher:
            keyPoster(48, .maskCommand)
        case .volumeUp:
            postSystemKey(type: 0)
        case .volumeDown:
            postSystemKey(type: 1)
        case .volumeMute:
            postSystemKey(type: 7)
        case .playPause:
            postSystemKey(type: 16)
        case .customShortcut:
            if let shortcut {
                if shortcut.isStandaloneModifier {
                    modifierKeyTapPoster(CGKeyCode(shortcut.keyCode), shortcut.cgEventFlags)
                } else {
                    keyPoster(CGKeyCode(shortcut.keyCode), shortcut.cgEventFlags)
                }
            }
        case .cyclePreset, .openRemoteMic, .openCodex, .openWorkBuddy, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openChromeBeta, .openSafari, .openZed:
            break
        }
        return true
    }

    private static func open(
        _ application: PresetApplication,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener
    ) {
        guard let url = applicationURL(application.bundleIdentifier) else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }

        applicationOpener(url, application) { error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) error=\(error.localizedDescription)"
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
            }
        }
    }

    private static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping (Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(error)
            if error == nil, application == .claude || application == .codex,
               let pid = runningApplication?.processIdentifier {
                focusPromptInput(pid: pid, bundleIdentifier: application.bundleIdentifier, attempt: 0)
            }
        }
    }

    /// Local addition: after 打开 Claude / 打开 Codex, put the caret in the
    /// prompt box so the voice key can dictate right away. Retries with a
    /// growing delay (~5 s total) to cover a cold launch.
    private static func focusPromptInput(pid: pid_t, bundleIdentifier: String, attempt: Int) {
        guard attempt < 8, isAccessibilityTrusted else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15 * Double(attempt + 1)) {
            let axApp = AXUIElementCreateApplication(pid)
            // Electron builds its web accessibility tree only when a client asks.
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let window = axAttribute(axApp, kAXFocusedWindowAttribute),
                  let input = promptInput(in: window as! AXUIElement)
            else {
                focusPromptInput(pid: pid, bundleIdentifier: bundleIdentifier, attempt: attempt + 1)
                return
            }
            let result = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AppLogger.shared.write(
                "APP ACTION focus_prompt bundle=\(bundleIdentifier) attempt=\(attempt) result=\(result.rawValue)"
            )
        }
    }

    /// Claude labels its prompt box "Prompt"; otherwise take the lowest text area.
    private static func promptInput(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var index = 0
        var lowest: (element: AXUIElement, y: CGFloat)?
        while index < queue.count, index < 8000 {
            let element = queue[index]
            index += 1
            if axAttribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole {
                if axAttribute(element, kAXDescriptionAttribute) as? String == "Prompt" { return element }
                var point = CGPoint.zero
                if let position = axAttribute(element, kAXPositionAttribute) {
                    AXValueGetValue(position as! AXValue, .cgPoint, &point)
                }
                if lowest == nil || point.y > lowest!.y { lowest = (element, point.y) }
            }
            if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return lowest?.element
    }

    private static func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = eventSource,
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postScrollWheel(delta: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func postKeyToFrontmostApplication(
        code: CGKeyCode,
        flags: CGEventFlags = []
    ) {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let source = eventSource,
              let down = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: code,
                  keyDown: true
              ),
              let up = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: code,
                  keyDown: false
              )
        else {
            postKey(code: code, flags: flags)
            return
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.postToPid(processID)
        up.postToPid(processID)
    }

    private static func postKeyState(
        code: CGKeyCode,
        flags: CGEventFlags,
        isDown: Bool
    ) -> Bool {
        guard let source = eventSource,
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: code,
                  keyDown: isDown
              )
        else { return false }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postFunctionKeyState(isDown: Bool) -> Bool {
        guard let source = eventSource,
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: weChatFunctionKeyCode,
                  keyDown: isDown
              )
        else { return false }
        event.type = .flagsChanged
        event.flags = isDown ? .maskSecondaryFn : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postModifierKeyState(
        code: CGKeyCode,
        flags: CGEventFlags,
        isDown: Bool
    ) -> Bool {
        guard let source = eventSource,
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: code,
                  keyDown: isDown
              )
        else { return false }
        event.type = .flagsChanged
        event.flags = isDown ? flags : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postModifierKeyPress(
        code: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard postModifierKeyState(code: code, flags: flags, isDown: true) else {
            return false
        }
        return postModifierKeyState(code: code, flags: flags, isDown: false)
    }

    private static func postKeyPress(
        code: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard let source = eventSource,
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postSystemKey(type: Int32) {
        postSystemKey(type: type, isDown: true)
        postSystemKey(type: type, isDown: false)
    }

    private static func postSystemKey(type: Int32, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let data1 = Int((type << 16) | Int32(keyState << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        guard let cgEvent = event.cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
