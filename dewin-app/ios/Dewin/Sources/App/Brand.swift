import SwiftUI

/// Dewin's palette, from the logo pack. Use these instead of raw system colors for brand surfaces;
/// keep semantic colors (EnvLevel, HealthScoreBadge) for health levels.
enum Brand {
    /// #0B0F1A: the icon background. Report page background, dark cards.
    static let navy = Color(red: 0x0B / 255, green: 0x0F / 255, blue: 0x1A / 255)
    /// Slightly lifted navy for cards on navy.
    static let navyRaised = Color(red: 0x15 / 255, green: 0x1B / 255, blue: 0x2B / 255)
    /// #0D9488: the wordmark's "win". The app accent in light mode.
    static let teal = Color(red: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255)
    /// #5EEAD4: the drop's bottom. "Good / clean" on dark backgrounds.
    static let aqua = Color(red: 0x5E / 255, green: 0xEA / 255, blue: 0xD4 / 255)
    /// #BAE6FD: the drop's top. Soft highlights.
    static let sky = Color(red: 0xBA / 255, green: 0xE6 / 255, blue: 0xFD / 255)
    /// #38BDF8: the motion lines in the wordmark.
    static let blue = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    /// Over the limit / needs attention, paired with aqua.
    static let orange = Color(red: 0xFB / 255, green: 0x92 / 255, blue: 0x3C / 255)
    /// Neutral / no strong signal.
    static let gray = Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255)

    /// The drop gradient (sky → aqua) used in the logo.
    static let dropGradient = LinearGradient(colors: [sky, aqua], startPoint: .top, endPoint: .bottom)
}

/// The person using the app. Only a first name, kept on the phone, for "Welcome back, …".
enum UserProfile {
    static let firstNameKey = "profile.firstName"

    static var firstName: String {
        (UserDefaults.standard.string(forKey: firstNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
