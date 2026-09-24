import Foundation
import SwiftData

enum AuthMode: String, CaseIterable, Identifiable, Sendable {
    case webSession
    case apiKey
    var id: String { rawValue }
    var title: String {
        switch self {
        case .webSession: "Iniciar sesión con Apple ID"
        case .apiKey: "API key (.p8)"
        }
    }
}

enum SessionState: String, Sendable {
    case unknown
    case valid
    case expired
}

/// Equipo (provider) de App Store Connect al que pertenece el usuario.
struct TeamInfo: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let publicId: String?
    let name: String
    let subType: String?
}

@Model
final class Connection {
    @Attribute(.unique) var id: UUID
    var name: String
    var issuerId: String
    var keyId: String
    var syncIntervalMinutes: Int
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var apps: [MonitoredApp] = []
    // Modo de conexión (los valores por defecto permiten migrar bases creadas antes del modo sesión).
    var authModeRaw: String = AuthMode.apiKey.rawValue
    // Modo sesión: la sesión vive en WKWebsiteDataStore(forIdentifier: id), nunca en SwiftData.
    var accountEmail: String?
    var accountName: String?
    var teamId: Int?
    var teamName: String?
    var teamsData: Data?
    var sessionStateRaw: String = SessionState.unknown.rawValue
    var sessionCheckedAt: Date?

    init(id: UUID = UUID(), name: String, issuerId: String, keyId: String,
         syncIntervalMinutes: Int = 0, createdAt: Date = .now, authMode: AuthMode = .apiKey) {
        self.id = id
        self.name = name
        self.issuerId = issuerId
        self.keyId = keyId
        self.syncIntervalMinutes = syncIntervalMinutes
        self.createdAt = createdAt
        self.authModeRaw = authMode.rawValue
    }

    var authMode: AuthMode {
        get { AuthMode(rawValue: authModeRaw) ?? .apiKey }
        set { authModeRaw = newValue.rawValue }
    }

    var sessionState: SessionState {
        get { SessionState(rawValue: sessionStateRaw) ?? .unknown }
        set { sessionStateRaw = newValue.rawValue }
    }

    var teams: [TeamInfo] {
        get { teamsData.flatMap { try? JSONDecoder().decode([TeamInfo].self, from: $0) } ?? [] }
        set { teamsData = try? JSONEncoder().encode(newValue) }
    }

    /// Intervalo efectivo de sincronización automática. En modo sesión el mínimo es 1 hora.
    var effectiveSyncIntervalMinutes: Int {
        guard syncIntervalMinutes > 0 else { return 0 }
        return authMode == .webSession ? max(syncIntervalMinutes, 60) : syncIntervalMinutes
    }

    /// Guarda los datos de la sesión web. Si todavía no hay equipo elegido, usa el equipo activo.
    func apply(_ session: ASCSessionInfo) {
        accountEmail = session.email
        accountName = session.fullName
        teams = session.teams
        if teamId == nil { teamId = session.team?.id }
        teamName = teams.first { $0.id == teamId }?.name ?? session.team?.name
        sessionState = .valid
        sessionCheckedAt = .now
    }
}

@Model
final class MonitoredApp {
    @Attribute(.unique) var appleId: String
    var name: String
    var bundleId: String
    var iconURL: URL?
    var isMonitored: Bool
    var lastSyncAt: Date?
    var connection: Connection?
    @Relationship(deleteRule: .cascade) var feedbacks: [Feedback] = []

    init(appleId: String, name: String, bundleId: String, iconURL: URL? = nil,
         isMonitored: Bool = true, connection: Connection? = nil) {
        self.appleId = appleId
        self.name = name
        self.bundleId = bundleId
        self.iconURL = iconURL
        self.isMonitored = isMonitored
        self.connection = connection
    }
}

@Model
final class Feedback {
    @Attribute(.unique) var appleId: String
    var kind: String
    var comment: String?
    var testerEmail: String?
    var testerName: String?
    var deviceModel: String?
    var deviceFamily: String?
    var osVersion: String?
    var locale: String?
    var timeZone: String?
    var batteryPercentage: Int?
    var connectionType: String?
    var appVersion: String?
    var buildNumber: String?
    var createdDate: Date
    var screenshotPaths: [String]
    var crashLogPath: String?
    var rawJSON: Data?
    var status: String
    var notes: String
    var app: MonitoredApp?

    init(appleId: String, kind: String, comment: String? = nil, testerEmail: String? = nil,
         testerName: String? = nil, deviceModel: String? = nil, deviceFamily: String? = nil,
         osVersion: String? = nil, locale: String? = nil, timeZone: String? = nil,
         batteryPercentage: Int? = nil, connectionType: String? = nil, appVersion: String? = nil,
         buildNumber: String? = nil, createdDate: Date = .now, screenshotPaths: [String] = [],
         crashLogPath: String? = nil, rawJSON: Data? = nil, status: String = "Nuevo",
         notes: String = "", app: MonitoredApp? = nil) {
        self.appleId = appleId
        self.kind = kind
        self.comment = comment
        self.testerEmail = testerEmail
        self.testerName = testerName
        self.deviceModel = deviceModel
        self.deviceFamily = deviceFamily
        self.osVersion = osVersion
        self.locale = locale
        self.timeZone = timeZone
        self.batteryPercentage = batteryPercentage
        self.connectionType = connectionType
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.createdDate = createdDate
        self.screenshotPaths = screenshotPaths
        self.crashLogPath = crashLogPath
        self.rawJSON = rawJSON
        self.status = status
        self.notes = notes
        self.app = app
    }
}

@Model
final class SyncRun {
    var appleAppId: String
    var startedAt: Date
    var finishedAt: Date?
    var newItems: Int
    var errorMessage: String?

    init(appleAppId: String, startedAt: Date = .now, finishedAt: Date? = nil,
         newItems: Int = 0, errorMessage: String? = nil) {
        self.appleAppId = appleAppId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.newItems = newItems
        self.errorMessage = errorMessage
    }
}

enum FeedbackStatus: String, CaseIterable, Identifiable {
    case new = "Nuevo"
    case inReview = "En revisión"
    case resolved = "Resuelto"
    case ignored = "Ignorado"
    var id: String { rawValue }
}
