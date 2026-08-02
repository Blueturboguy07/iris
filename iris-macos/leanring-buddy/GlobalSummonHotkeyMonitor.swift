//
//  GlobalSummonHotkeyMonitor.swift
//  leanring-buddy
//
//  Captures the global summon hotkey (ctrl + option) while the app is running
//  in the background. Uses a listen-only CGEvent tap so modifier-only shortcuts
//  are detected reliably system-wide. Pressing the hotkey toggles the
//  companion panel so the user can type a question from anywhere.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// The keyboard shortcut that summons the companion panel, plus the logic
/// for turning raw CGEvent modifier changes into pressed/released transitions.
enum SummonHotkeyShortcut {
    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    /// The modifier combination that acts as the summon hotkey.
    static let summonModifierFlags: NSEvent.ModifierFlags = [.control, .option]
    static let displayText = "ctrl + option"
    static let keyCapsuleLabels = ["ctrl", "option"]

    static func shortcutTransition(
        for eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        // The summon hotkey is modifier-only, so only flagsChanged events matter.
        guard eventType == .flagsChanged else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isShortcutCurrentlyPressed = modifierFlags.contains(summonModifierFlags)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

final class GlobalSummonHotkeyMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<SummonHotkeyShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would misfire
        // a transition when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalSummonHotkeyMonitor = Unmanaged<GlobalSummonHotkeyMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalSummonHotkeyMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global summon hotkey: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global summon hotkey: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let shortcutTransition = SummonHotkeyShortcut.shortcutTransition(
            for: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
