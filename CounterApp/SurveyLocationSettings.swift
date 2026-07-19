import Foundation

enum SurveyLocationMode: String, Codable, CaseIterable {
    case device
    case fixed
    case none

    var title: String {
        switch self {
        case .device: return "Device Location"
        case .fixed: return "Fixed Survey Location"
        case .none: return "No Location"
        }
    }
}

struct SavedSurveyLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var formattedAddress: String?
    var latitude: Double?
    var longitude: Double?
    var mapItemIdentifier: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var hasValidCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var needsCoordinateResolution: Bool {
        guard !hasValidCoordinate else { return false }
        return !(formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func resolved(
        with candidate: SurveyLocationAddressCandidate,
        confirmedName: String? = nil,
        at date: Date = Date()
    ) -> Self {
        var updated = self
        let trimmedName = confirmedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { updated.name = trimmedName }
        updated.formattedAddress = candidate.formattedAddress
        updated.latitude = candidate.latitude
        updated.longitude = candidate.longitude
        updated.mapItemIdentifier = candidate.mapItemIdentifier
        updated.updatedAt = date
        return updated
    }
}

struct SurveyLocationAddressCandidate: Equatable {
    let name: String?
    let formattedAddress: String
    let latitude: Double
    let longitude: Double
    let mapItemIdentifier: String?

    var hasValidCoordinate: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

protocol SurveyLocationAddressResolving {
    func candidates(forTypedAddress address: String) async throws -> [SurveyLocationAddressCandidate]
}

enum ManualAddressResolutionOutcome: Equatable {
    case candidates([SurveyLocationAddressCandidate])
    case addressOnly
}

enum ManualSurveyLocationAddressResolution {
    static func resolve(
        typedAddress: String,
        using resolver: SurveyLocationAddressResolving
    ) async -> ManualAddressResolutionOutcome {
        do {
            let candidates = try await resolver.candidates(forTypedAddress: typedAddress)
                .filter(\.hasValidCoordinate)
            return candidates.isEmpty ? .addressOnly : .candidates(candidates)
        } catch {
            return .addressOnly
        }
    }
}

struct SessionLocationInfo: Codable, Equatable {
    var mode: SurveyLocationMode
    var collectionMethod: String
    var savedLocationId: UUID?
    var locationName: String?
    var formattedAddress: String?
    var mapItemIdentifier: String?
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case mode
        case collectionMethod = "collection_method"
        case savedLocationId = "saved_location_id"
        case locationName = "location_name"
        case formattedAddress = "formatted_address"
        case mapItemIdentifier = "map_item_identifier"
        case latitude
        case longitude
    }

    var hasValidCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var needsCoordinateResolutionOnRetry: Bool {
        guard mode == .fixed, !hasValidCoordinate else { return false }
        return !(formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func resolved(with candidate: SurveyLocationAddressCandidate, confirmedName: String? = nil) -> Self {
        var updated = self
        let trimmedName = confirmedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { updated.locationName = trimmedName }
        updated.formattedAddress = candidate.formattedAddress
        updated.mapItemIdentifier = candidate.mapItemIdentifier
        updated.latitude = candidate.latitude
        updated.longitude = candidate.longitude
        return updated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(collectionMethod, forKey: .collectionMethod)
        try container.encodeIfPresent(savedLocationId, forKey: .savedLocationId)
        try container.encodeIfPresent(locationName, forKey: .locationName)
        try container.encodeIfPresent(formattedAddress, forKey: .formattedAddress)
        try container.encodeIfPresent(mapItemIdentifier, forKey: .mapItemIdentifier)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }

    static func fixed(_ location: SavedSurveyLocation) -> Self {
        Self(
            mode: .fixed,
            collectionMethod: "saved_survey_location",
            savedLocationId: location.id,
            locationName: location.name,
            formattedAddress: location.formattedAddress,
            mapItemIdentifier: location.mapItemIdentifier,
            latitude: location.latitude,
            longitude: location.longitude
        )
    }

    static let intentionallyDisabled = Self(
        mode: .none,
        collectionMethod: "intentionally_not_collected",
        savedLocationId: nil,
        locationName: nil,
        formattedAddress: nil,
        mapItemIdentifier: nil,
        latitude: nil,
        longitude: nil
    )

    static func device(
        collectionMethod: String,
        name: String? = nil,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Self {
        Self(
            mode: .device,
            collectionMethod: collectionMethod,
            savedLocationId: nil,
            locationName: name,
            formattedAddress: address,
            mapItemIdentifier: nil,
            latitude: latitude,
            longitude: longitude
        )
    }
}

final class SavedSurveyLocationStore {
    static let shared = SavedSurveyLocationStore()

    enum DefaultsKeys {
        static let locations = "SavedSurveyLocations.v1"
        static let mode = "SurveyLocationMode.v1"
        static let activeLocationId = "ActiveSavedSurveyLocationID.v1"
    }

    private let defaults: UserDefaults
    private(set) var loadErrorDescription: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: SurveyLocationMode {
        get {
            guard let raw = defaults.string(forKey: DefaultsKeys.mode) else { return .device }
            return SurveyLocationMode(rawValue: raw) ?? .device
        }
        set { defaults.set(newValue.rawValue, forKey: DefaultsKeys.mode) }
    }

    var activeLocationId: UUID? {
        get { defaults.string(forKey: DefaultsKeys.activeLocationId).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: DefaultsKeys.activeLocationId) }
    }

    var activeLocation: SavedSurveyLocation? {
        guard let activeLocationId else { return nil }
        return locations.first { $0.id == activeLocationId }
    }

    var locations: [SavedSurveyLocation] {
        guard let data = defaults.data(forKey: DefaultsKeys.locations) else {
            loadErrorDescription = nil
            return []
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let values = try decoder.decode([SavedSurveyLocation].self, from: data)
            loadErrorDescription = nil
            return values
        } catch {
            loadErrorDescription = "Saved locations could not be read. Existing preference data was left unchanged."
            return []
        }
    }

    var sortedLocations: [SavedSurveyLocation] {
        let activeId = activeLocationId
        return locations.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            let lhsUsed = lhs.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func save(_ location: SavedSurveyLocation, makeActive: Bool = false) throws {
        var values = locations
        if loadErrorDescription != nil {
            throw NSError(
                domain: "SavedSurveyLocationStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: loadErrorDescription!]
            )
        }
        if let index = values.firstIndex(where: { $0.id == location.id }) {
            values[index] = location
        } else {
            values.append(location)
        }
        try persist(values)
        if makeActive { activeLocationId = location.id }
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let wasActive = activeLocationId == id
        let values = locations
        if loadErrorDescription != nil {
            throw NSError(
                domain: "SavedSurveyLocationStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: loadErrorDescription!]
            )
        }
        try persist(values.filter { $0.id != id })
        if wasActive { activeLocationId = nil }
        return wasActive
    }

    func select(id: UUID) {
        guard locations.contains(where: { $0.id == id }) else { return }
        activeLocationId = id
    }

    func markActiveLocationUsed(at date: Date = Date()) throws -> SavedSurveyLocation? {
        guard var activeLocation else { return nil }
        activeLocation.lastUsedAt = date
        try save(activeLocation)
        return activeLocation
    }

    func duplicateCandidate(for candidate: SavedSurveyLocation) -> SavedSurveyLocation? {
        let normalizedAddress = Self.normalize(candidate.formattedAddress)
        return locations.first { existing in
            guard existing.id != candidate.id else { return false }
            if let lhs = existing.mapItemIdentifier, let rhs = candidate.mapItemIdentifier,
               !lhs.isEmpty, lhs == rhs {
                return true
            }
            if existing.hasValidCoordinate, candidate.hasValidCoordinate,
               let lhsLat = existing.latitude, let lhsLon = existing.longitude,
               let rhsLat = candidate.latitude, let rhsLon = candidate.longitude,
               abs(lhsLat - rhsLat) < 0.00001, abs(lhsLon - rhsLon) < 0.00001 {
                return true
            }
            let existingAddress = Self.normalize(existing.formattedAddress)
            return !normalizedAddress.isEmpty && normalizedAddress == existingAddress
        }
    }

    private func persist(_ values: [SavedSurveyLocation]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(values)
        defaults.set(data, forKey: DefaultsKeys.locations)
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
