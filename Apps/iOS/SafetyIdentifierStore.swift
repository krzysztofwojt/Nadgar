import Foundation

struct SafetyIdentifierStore {
    private let defaults: UserDefaults
    private let key = "OpenAISafetyIdentifier"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identifier() -> String {
        if let existing = defaults.string(forKey: key) {
            return existing
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }
}
