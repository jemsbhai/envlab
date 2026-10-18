import SwiftUI

/// The Health tab (air & water): Today, Week, Log and Map under one segmented control.
struct HealthView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            Group {
                switch router.health {
                case .today: HealthTodayView()
                case .week: HealthWeekView()
                case .log: HealthLogView()
                case .map: EnvironmentView()
                }
            }
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $router.health) {
                        ForEach(Router.HealthSection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            }
        }
    }
}
