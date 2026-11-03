import Carbon.HIToolbox

/// System-wide shortcuts (⌃⌥⌘ + key) so the prompter can be driven while another app is focused.
final class HotKeys {
    enum Action: UInt32 {
        case next = 1, previous, toggleListening, toggleOverlay

        var keyCode: Int {
            switch self {
            case .next: return kVK_RightArrow
            case .previous: return kVK_LeftArrow
            case .toggleListening: return kVK_ANSI_L
            case .toggleOverlay: return kVK_ANSI_H
            }
        }
    }

    static let modifierSymbol = "⌃⌥⌘"

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    fileprivate var callback: ((Action) -> Void)?

    func register(_ callback: @escaping (Action) -> Void) {
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { me.callback?(action) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for action in [Action.next, .previous, .toggleListening, .toggleOverlay] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5450_5254), id: action.rawValue) // 'TPRT'
            RegisterEventHotKey(UInt32(action.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    deinit {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
