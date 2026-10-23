import Foundation
import Observation
import RackoonCore

/// The Read-only switch, as on the Mac: stored here and mirrored into the one `ActionPolicy` every session is created
/// with, so the service layer (not just the UI) refuses changes while it is on.
@MainActor @Observable
final class SafetyStore {
    static let key = "readOnlyMode"

    private(set) var readOnly: Bool
    @ObservationIgnored let policy: ActionPolicy
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let on = defaults.bool(forKey: Self.key)
        readOnly = on
        policy = ActionPolicy(readOnly: on)
    }

    func setReadOnly(_ on: Bool) {
        guard on != readOnly else { return }
        readOnly = on
        policy.isReadOnly = on
        defaults.set(on, forKey: Self.key)
    }
}
