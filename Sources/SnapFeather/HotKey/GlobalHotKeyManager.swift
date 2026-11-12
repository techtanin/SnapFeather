import Carbon
import Foundation

@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?

    private let hotKeySignature: OSType = 0x534E4150 // "SNAP"
    private let hotKeyID: UInt32 = 1

    private init() {}

    func register(shortcut: HotKeyShortcut, onTrigger: @escaping @MainActor () -> Void) {
        unregister()
        self.handler = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            if status == noErr && pressedID.id == 1 {
                Task { @MainActor in
                    GlobalHotKeyManager.shared.fire()
                }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        let carbonHotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            carbonHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        Diagnostics.log("HotKey register '\(shortcut.displayLabel)' installStatus=\(installStatus) regStatus=\(regStatus)")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func fire() {
        handler?()
    }
}
