import ActivityKit
import Foundation

/// Starts, updates and ends the navigation Live Activity from Drive Mode.
@MainActor
final class NavigationActivity {
    private var activity: Activity<NavigationActivityAttributes>?
    private var lastSent: NavigationActivityAttributes.ContentState?
    private var lastSentAt = Date.distantPast

    func start(destination: String, state: NavigationActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: NavigationActivityAttributes(destination: destination),
                                         content: ActivityContent(state: state, staleDate: nil))
        lastSent = state
        lastSentAt = .now
    }

    /// Sends a new state when the instruction changes, or every 10 seconds for the distances (iOS limits updates).
    func update(_ state: NavigationActivityAttributes.ContentState) {
        guard let activity else { return }
        let instructionChanged = state.instruction != lastSent?.instruction
        guard instructionChanged || Date.now.timeIntervalSince(lastSentAt) > 10 else { return }
        lastSent = state
        lastSentAt = .now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
