import Foundation

struct InterviewerProfile: Codable, Equatable {
    let interviewerId: String
    let name: String
    let email: String
    let identityScope: String

    enum CodingKeys: String, CodingKey {
        case interviewerId = "interviewer_id"
        case name
        case email
        case identityScope = "identity_scope"
    }

    init(interviewerId: String? = nil, name: String, email: String, identityScope: String) {
        let normalizedEmail = Self.normalizedEmail(email)
        self.interviewerId = interviewerId.map(Self.normalizedEmail) ?? normalizedEmail
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = normalizedEmail
        self.identityScope = identityScope
    }

    static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidEmail(_ value: String) -> Bool {
        let email = normalizedEmail(value)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].contains(".")
    }
}

final class InterviewerProfileStore {
    static let shared = InterviewerProfileStore()

    private enum DefaultsKeys {
        static let profiles = "InterviewerProfiles"
        static let currentInterviewerId = "CurrentInterviewerID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var currentProfile: InterviewerProfile? {
        guard let currentId = defaults.string(forKey: DefaultsKeys.currentInterviewerId) else {
            return nil
        }
        return profiles.first { $0.interviewerId == currentId }
    }

    var profiles: [InterviewerProfile] {
        guard let data = defaults.data(forKey: DefaultsKeys.profiles),
              let decoded = try? JSONDecoder().decode([InterviewerProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveCurrentProfile(_ profile: InterviewerProfile) {
        var updated = profiles.filter { $0.interviewerId != profile.interviewerId }
        updated.insert(profile, at: 0)
        saveProfiles(updated)
        defaults.set(profile.interviewerId, forKey: DefaultsKeys.currentInterviewerId)
    }

    func clearCurrentProfile() {
        defaults.removeObject(forKey: DefaultsKeys.currentInterviewerId)
    }

    private func saveProfiles(_ profiles: [InterviewerProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: DefaultsKeys.profiles)
    }
}
