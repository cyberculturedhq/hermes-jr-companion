import Foundation
import Observation

struct NotificationPreferenceFailure: Identifiable {
    let id = UUID()
    let requestedValue: Bool
    let message: String
}

/// Keeps the user's latest choice visible while serializing server updates.
@MainActor @Observable
final class NotificationPreferenceUpdate {
    private(set) var requestedValue: Bool?
    private(set) var isSaving = false
    var failure: NotificationPreferenceFailure?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var revision = 0

    func request(_ enabled: Bool, apply: @escaping @MainActor (Bool) async -> String?) {
        requestedValue = enabled
        failure = nil
        revision += 1
        guard task == nil else { return }
        isSaving = true
        let generation = generation
        task = Task {
            while let requested = requestedValue {
                let revision = revision
                let error = await apply(requested)
                guard self.generation == generation, !Task.isCancelled else { return }
                // Finish the newest intent even if an older request failed.
                guard self.revision == revision else { continue }
                requestedValue = nil
                if let error {
                    failure = NotificationPreferenceFailure(requestedValue: requested, message: error)
                }
            }
            isSaving = false
            task = nil
        }
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        requestedValue = nil
        failure = nil
        isSaving = false
    }
}
