//
//  AccountSorting.swift
//  Quotio
//
//  Pure helpers for ordering provider account lists so that accounts
//  currently in use are displayed at the top.
//

import Foundation

nonisolated enum AccountSorting {
    /// Returns `items` with every element matching `isActive` moved to the front.
    ///
    /// The relative order inside each partition (active / inactive) is preserved,
    /// so the existing display order remains the tie-breaker. When nothing is
    /// active the input is returned unchanged.
    static func prioritizingActive<T>(_ items: [T], isActive: (T) -> Bool) -> [T] {
        var active: [T] = []
        var inactive: [T] = []
        for item in items {
            if isActive(item) {
                active.append(item)
            } else {
                inactive.append(item)
            }
        }
        guard !active.isEmpty else { return items }
        return active + inactive
    }
}
