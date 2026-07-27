import CSQLite
import Foundation

final class SQLiteProjectStore {
    static let shared = SQLiteProjectStore()

    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        do {
            let fileManager = FileManager.default
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appendingPathComponent("SoundScape", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let databaseURL = directory.appendingPathComponent("SoundScape.sqlite3")

            if sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK {
                execute("PRAGMA journal_mode = WAL")
                execute("PRAGMA foreign_keys = ON")
                createSchema()
            }
        } catch {
            database = nil
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func loadSessions() -> [AudioSession] {
        guard let database else { return [] }
        let sql = "SELECT payload FROM projects ORDER BY sort_order ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [AudioSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            if let project = try? decoder.decode(PersistedProject.self, from: data) {
                result.append(project.audioSession)
            }
        }
        return result
    }

    func saveSessions(_ sessions: [AudioSession]) {
        guard let database else { return }
        execute("BEGIN IMMEDIATE TRANSACTION")
        execute("DELETE FROM projects")

        let sql = """
            INSERT INTO projects (id, payload, sort_order, updated_at)
            VALUES (?, ?, ?, ?)
            """

        for (index, session) in sessions.enumerated() {
            guard let data = try? encoder.encode(PersistedProject(session)) else { continue }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }

            sqlite3_bind_text(
                statement,
                1,
                session.id.uuidString,
                -1,
                transient
            )
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    2,
                    bytes.baseAddress,
                    Int32(data.count),
                    transient
                )
            }
            sqlite3_bind_int(statement, 3, Int32(index))
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        execute("COMMIT")
    }

    func stringSetting(forKey key: String) -> String? {
        guard let database else { return nil }
        let sql = "SELECT value FROM settings WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }

    func setSetting(_ value: String?, forKey key: String) {
        guard let database else { return }

        if let value {
            let sql = """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            sqlite3_step(statement)
        } else {
            let sql = "DELETE FROM settings WHERE key = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_step(statement)
        }
    }

    private func createSchema() {
        execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
            """
        )
        execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT
            )
            """
        )
    }

    private func execute(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }
}

private struct PersistedProject: Codable {
    let id: UUID
    let name: String
    let projectDescription: String
    let icon: String
    let status: SessionStatus
    let sampleRate: String
    let nodes: [PersistedNode]
    let connections: [PersistedConnection]

    init(_ session: AudioSession) {
        id = session.id
        name = session.name
        projectDescription = session.description
        icon = session.icon
        status = session.status == .running ? .ready : session.status
        sampleRate = session.sampleRate
        nodes = session.nodes.map(PersistedNode.init)
        connections = session.connections.map(PersistedConnection.init)
    }

    var audioSession: AudioSession {
        AudioSession(
            id: id,
            name: name,
            description: projectDescription,
            icon: icon,
            accent: DemoContent.cyan,
            status: status == .running ? .ready : status,
            sampleRate: sampleRate,
            nodes: nodes.map(\.audioNode),
            connections: connections.map(\.graphConnection)
        )
    }
}

private struct PersistedNode: Codable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let kind: NodeKind
    let x: Double
    let y: Double
    let nodeType: AudioNodeType
    let isEnabled: Bool
    let level: Double
    let gain: Double
    let deviceUID: String?
    let upmixMonoToStereo: Bool?
    let applicationBundleIdentifier: String?
    let excludesCurrentProcessAudio: Bool?
    let parameterValues: [String: Double]
    let parameterConfigurationVersion: Int?
    let audioUnitState: Data?
    let recordingDirectoryPath: String?
    let recordingFormat: RecorderFileFormat?
    let recordingFilePrefix: String?
    let combineInputSettings: [String: CombineInputSettings]?
    let combineOutputMode: ChannelMode?
    let parametricEQBands: [ParametricEQBand]?

    init(_ node: AudioNode) {
        id = node.id
        title = node.title
        subtitle = node.subtitle
        icon = node.icon
        kind = node.kind
        x = node.position.x
        y = node.position.y
        nodeType = node.nodeType
        isEnabled = node.isEnabled
        level = node.level
        gain = node.gain
        deviceUID = node.deviceUID
        upmixMonoToStereo = node.upmixMonoToStereo
        applicationBundleIdentifier = node.applicationBundleIdentifier
        excludesCurrentProcessAudio = node.excludesCurrentProcessAudio
        parameterValues = node.parameterValues
        parameterConfigurationVersion = 1
        audioUnitState = node.audioUnitState
        recordingDirectoryPath = node.recordingDirectoryPath
        recordingFormat = node.recordingFormat
        recordingFilePrefix = node.recordingFilePrefix
        combineInputSettings = node.combineInputSettings
        combineOutputMode = node.combineOutputMode
        parametricEQBands = node.parametricEQBands
    }

    var audioNode: AudioNode {
        AudioNode(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: icon,
            kind: kind,
            accent: DemoContent.cyan,
            position: CGPoint(x: x, y: y),
            nodeType: nodeType,
            isEnabled: isEnabled,
            level: level,
            gain: gain,
            deviceUID: deviceUID,
            upmixMonoToStereo: upmixMonoToStereo ?? true,
            applicationBundleIdentifier: applicationBundleIdentifier,
            excludesCurrentProcessAudio: excludesCurrentProcessAudio ?? true,
            parameterValues: restoredParameterValues,
            audioUnitState: audioUnitState,
            recordingDirectoryPath: recordingDirectoryPath,
            recordingFormat: recordingFormat ?? .wav,
            recordingFilePrefix: recordingFilePrefix ?? "SoundScape",
            combineInputSettings: combineInputSettings ?? [:],
            combineOutputMode: combineOutputMode ?? .stereo,
            parametricEQBands: parametricEQBands ?? []
        )
    }

    private var restoredParameterValues: [String: Double] {
        guard parameterConfigurationVersion == nil,
              case .audioUnit(let descriptor) = nodeType,
              descriptor.name.localizedCaseInsensitiveCompare("DeeGate")
                == .orderedSame else {
            return parameterValues
        }

        var migrated = parameterValues
        // DeeGate's normalized Level=1 maps to a 0 dB threshold, which closes
        // the gate for practically every microphone signal. Early builds could
        // persist that value without a meaningful dB label.
        if (migrated["808326999"] ?? 0) >= 0.999 {
            migrated["808326999"] = 0
        }
        return migrated
    }
}

private struct PersistedConnection: Codable {
    let id: UUID?
    let from: String
    let to: String
    let isReference: Bool?

    init(_ connection: GraphConnection) {
        id = connection.id
        from = connection.from
        to = connection.to
        isReference = connection.isReference
    }

    var graphConnection: GraphConnection {
        GraphConnection(
            id: id ?? UUID(),
            from: from,
            to: to,
            isReference: isReference ?? false
        )
    }
}
