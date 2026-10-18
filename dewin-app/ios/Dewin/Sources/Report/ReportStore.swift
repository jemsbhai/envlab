import Foundation
import Observation
import SwiftData

/// Loads the 90-day report and handles "Delete my data".
@Observable
@MainActor
final class ReportStore {
    static let days = 90

    private(set) var report: ExposureReport?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isDeleting = false

    @ObservationIgnored private let backend: () -> DewinBackend
    @ObservationIgnored private let context: ModelContext
    /// Runs after a successful delete (the app reconnects with the new client ID).
    @ObservationIgnored var onDeleted: (() -> Void)?

    init(context: ModelContext, backend: @escaping () -> DewinBackend) {
        self.context = context
        self.backend = backend
    }

    /// Loads once; pass `force` to reload (pull to refresh, after switching backends).
    func load(force: Bool = false) async {
        guard force || report == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await backend().fetchReport(.init(clientId: BackendSettings.clientID, days: Self.days,
                                                           timezone: TimeZone.current.identifier))
            error = nil
        } catch {
            self.error = error.localizedDescription
            NSLog("[Report] load failed: %@", String(describing: error))
        }
    }

    /// Deletes the server's copy first (so a failure leaves everything in place), then this phone's:
    /// meals and photos, the report, and the client ID (a fresh one is made on next use).
    func deleteEverything() async throws {
        isDeleting = true
        defer { isDeleting = false }
        try await backend().deleteMyData(clientId: BackendSettings.clientID)
        try context.delete(model: Meal.self)
        try context.save()
        report = nil
        UserDefaults.standard.removeObject(forKey: BackendSettings.clientIDKey)
        NSLog("[Report] all data deleted")
        onDeleted?()
    }
}
