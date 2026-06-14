//
//  WidgetCommandStatus.swift
//  BetterBlueWidget
//
//  Tiny app-group store recording the last command a user triggered
//  from a widget button. Lets the widget optimistically show
//  "<command> requested at <time>" in place of the last-updated time
//  until a real status refresh supersedes it.
//

import Foundation

enum WidgetCommandStatus {
    // Same app group the shared SwiftData store + AppSettings use, so
    // the value written by the button intent is visible to the widget.
    private static let suiteName = "group.com.betterblue.shared"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }
    private static func key(_ vin: String) -> String { "widgetCommand.\(vin)" }

    /// Record that `command` was requested for `vin` at `date` (default
    /// now). Both values are plist types so they round-trip through
    /// UserDefaults.
    static func record(command: String, vin: String, at date: Date = Date()) {
        defaults?.set(["command": command, "date": date], forKey: key(vin))
    }

    /// The last command requested for `vin`, if any.
    static func latest(vin: String) -> (command: String, date: Date)? {
        guard let dict = defaults?.dictionary(forKey: key(vin)),
              let command = dict["command"] as? String,
              let date = dict["date"] as? Date else {
            return nil
        }
        return (command, date)
    }
}
