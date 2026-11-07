//
//  KeyBindings.swift
//  FITS Blaster
//

/// The current key and ⇧ setting of every action, read once from `AppSettings`: the input of
/// `KeyDispatcher` and the one focused value the menu items read their shortcuts from.
struct KeyBindings: Equatable, Sendable {
    private var keys: [KeyAction: String]
    private var shifts: [KeyAction: Bool]
    /// The actions of each kind in `KeyBinding.all`'s order (the first match wins).
    private var order: [KeyBinding.Kind: [KeyAction]]

    @MainActor
    init(settings: AppSettings) {
        var keys = [KeyAction: String](), shifts = [KeyAction: Bool](), order = [KeyBinding.Kind: [KeyAction]]()
        for binding in KeyBinding.all {
            keys[binding.action] = settings[keyPath: binding.key]
            if let shift = binding.shift { shifts[binding.action] = settings[keyPath: shift] }
            order[binding.kind, default: []].append(binding.action)
        }
        self.keys = keys
        self.shifts = shifts
        self.order = order
    }

    /// Explicit keys and ⇧ settings (tests), in the table's order. Actions not given have no key.
    @MainActor
    init(keys: [KeyAction: String], shifts: [KeyAction: Bool] = [:]) {
        var order = [KeyBinding.Kind: [KeyAction]]()
        for binding in KeyBinding.all { order[binding.kind, default: []].append(binding.action) }
        self.keys = keys
        self.shifts = shifts
        self.order = order
    }

    /// The key string of `action` ("x", "↑", …); empty when it has none.
    func key(_ action: KeyAction) -> String { keys[action] ?? "" }

    /// True when the ⌘ shortcut of `action` also needs ⇧.
    func usesShift(_ action: KeyAction) -> Bool { shifts[action] ?? false }

    /// The actions of `kind` in the table's order.
    func actions(_ kind: KeyBinding.Kind) -> [KeyAction] { order[kind] ?? [] }
}
