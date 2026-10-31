//
//  ColourProxies.swift
//  FITS Blaster
//
//  The colour proxies a load keeps from Phase A until its folder's colour render, within
//  a memory budget (master-plan 9f part 2b). A frame whose proxy doesn't fit gets none and
//  is read again for its colour render, as before.
//

import Foundation

actor ColourProxies {

    /// The budget: a quarter of the Mac's memory (4 GB on 16 GB: a 140-frame night at a
    /// display size of 1024 takes 1.2 GB).
    static let defaultLimit = Int(ProcessInfo.processInfo.physicalMemory / 4)

    let limitBytes: Int
    private var proxies: [UUID: ColourProxy] = [:]
    /// Bytes of the proxies kept and of those being made.
    private(set) var usedBytes = 0
    /// Colour renders made from a proxy since the last `discardAll`, for the tests.
    private(set) var rendersFromProxy = 0

    init(limitBytes: Int = ColourProxies.defaultLimit) {
        self.limitBytes = limitBytes
    }

    /// Reserves room for a proxy of `bytes`; false when it doesn't fit the budget.
    func reserve(_ bytes: Int) -> Bool {
        guard usedBytes + bytes <= limitBytes else { return false }
        usedBytes += bytes
        return true
    }

    /// Gives back a reservation whose proxy couldn't be made.
    func cancelReservation(_ bytes: Int) {
        usedBytes -= bytes
    }

    /// Keeps the proxy made in a reserved room.
    func store(_ proxy: ColourProxy, for id: UUID) {
        if let old = proxies.updateValue(proxy, forKey: id) { usedBytes -= old.byteCount }
    }

    /// The frame's proxy, removed from the store; nil when it has none.
    func take(_ id: UUID) -> ColourProxy? {
        guard let proxy = proxies.removeValue(forKey: id) else { return nil }
        usedBytes -= proxy.byteCount
        rendersFromProxy += 1
        return proxy
    }

    /// Drops every proxy left (a frame the colour render didn't reach: Cancel, a colour
    /// toggle meanwhile, a frame without clips). Called when a load ends.
    func discardAll() {
        for proxy in proxies.values { usedBytes -= proxy.byteCount }
        proxies.removeAll()
    }

    /// For the tests: starts counting renders from proxies again.
    func resetCount() {
        rendersFromProxy = 0
    }

    var count: Int { proxies.count }
}
