// Add `let regionalAir: DewinRegionalAir?` to the app's existing Exposure model.
// All response additions are optional; older persisted records omit this field.
// Illustrative starter, not compiled in the team's Xcode project.
import Foundation

struct DewinRegionalAirEnvelope: Decodable {
    let regionalAir: DewinRegionalAir?
}

struct DewinRegionalAir: Decodable {
    let provider: String
    let dataType: String
    let label: String
    let status: String
    let fetchedAt: String
    let measurements: [DewinRegionalAirMeasurement]
    let error: String?
}

struct DewinRegionalAirMeasurement: Decodable {
    let metric: String
    let value: Double
    let unit: String
    let validFrom: String
    let validTo: String
    let issuedAt: String
    let sourceUrl: URL
}

// From DewinSocket's existing dictionary callback:
// let data = try JSONSerialization.data(withJSONObject: exposure)
// let regional = try JSONDecoder().decode(DewinRegionalAirEnvelope.self, from: data).regionalAir
// Show "NOAA forecast data" independently of the local exposure status.
// Keep UTC date strings here so the app can use its existing RFC3339 parser
// with support for timestamps both with and without fractional seconds.
