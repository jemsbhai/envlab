import SwiftUI

/// The Food tab: Today, Week and Log under one segmented control.
struct FoodView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            Group {
                switch router.food {
                case .today: FoodTodayView()
                case .week: FoodWeekView()
                case .log: FoodLogView()
                }
            }
            .navigationTitle("Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $router.food) {
                        ForEach(Router.FoodSection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
        }
    }
}
