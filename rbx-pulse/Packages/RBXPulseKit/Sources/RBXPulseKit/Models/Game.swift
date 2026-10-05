import Foundation

/// A Roblox experience the creator tracks. `id` is the Roblox universe ID.
public struct Game: Identifiable, Hashable, Codable, Sendable {
    public let id: Int64
    public var rootPlaceID: Int64
    public var name: String
    public var iconURL: URL?
    public var isFavourite: Bool
    public var isWorkingOn: Bool
    public var stats: GameStats

    public init(
        id: Int64,
        rootPlaceID: Int64,
        name: String,
        iconURL: URL? = nil,
        isFavourite: Bool = false,
        isWorkingOn: Bool = false,
        stats: GameStats
    ) {
        self.id = id
        self.rootPlaceID = rootPlaceID
        self.name = name
        self.iconURL = iconURL
        self.isFavourite = isFavourite
        self.isWorkingOn = isWorkingOn
        self.stats = stats
    }
}

/// Point-in-time numbers for a game, as reported by the backend.
public struct GameStats: Hashable, Codable, Sendable {
    /// Concurrent users right now.
    public var ccu: Int
    /// CCU at the same time yesterday, for the change indicator. `nil` when unknown.
    public var ccuYesterday: Int?
    public var visits: Int64
    public var favourites: Int64
    /// Robux earned in the last 24 hours. `nil` when the creator hasn't granted revenue access.
    public var robux24h: Int64?
    public var updatedAt: Date

    public init(
        ccu: Int,
        ccuYesterday: Int? = nil,
        visits: Int64,
        favourites: Int64,
        robux24h: Int64? = nil,
        updatedAt: Date
    ) {
        self.ccu = ccu
        self.ccuYesterday = ccuYesterday
        self.visits = visits
        self.favourites = favourites
        self.robux24h = robux24h
        self.updatedAt = updatedAt
    }

    /// Fractional change in CCU versus yesterday (0.25 == +25%). `nil` when there is no baseline.
    public var ccuChange: Double? {
        guard let ccuYesterday, ccuYesterday > 0 else { return nil }
        return Double(ccu - ccuYesterday) / Double(ccuYesterday)
    }
}
