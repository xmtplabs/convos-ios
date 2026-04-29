import ConvosConnections
import Foundation
import GRDB

public actor GRDBEnablementStore: EnablementStore {
    private let dbWriter: any DatabaseWriter
    private let dbReader: any DatabaseReader

    public init(dbWriter: any DatabaseWriter, dbReader: any DatabaseReader) {
        self.dbWriter = dbWriter
        self.dbReader = dbReader
    }

    public func isEnabled(kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async -> Bool {
        (try? await dbReader.read { db in
            try DBConnectionEnablement
                .filter(DBConnectionEnablement.Columns.kind == kind.rawValue)
                .filter(DBConnectionEnablement.Columns.capability == capability.rawValue)
                .filter(DBConnectionEnablement.Columns.conversationId == conversationId)
                .fetchOne(db) != nil
        }) ?? false
    }

    public func setEnabled(_ enabled: Bool, kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async {
        try? await dbWriter.write { db in
            if enabled {
                try DBConnectionEnablement(
                    kind: kind.rawValue,
                    capability: capability.rawValue,
                    conversationId: conversationId,
                    createdAt: Date(),
                    updatedAt: Date()
                ).save(db, onConflict: .replace)
            } else {
                _ = try DBConnectionEnablement
                    .filter(DBConnectionEnablement.Columns.kind == kind.rawValue)
                    .filter(DBConnectionEnablement.Columns.capability == capability.rawValue)
                    .filter(DBConnectionEnablement.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }
        }
    }

    public func conversationIds(enabledFor kind: ConnectionKind, capability: ConnectionCapability) async -> [String] {
        (try? await dbReader.read { db in
            try String.fetchAll(
                db,
                DBConnectionEnablement
                    .filter(DBConnectionEnablement.Columns.kind == kind.rawValue)
                    .filter(DBConnectionEnablement.Columns.capability == capability.rawValue)
                    .select(DBConnectionEnablement.Columns.conversationId)
            )
        }) ?? []
    }

    public func allEnablements() async -> [Enablement] {
        (try? await dbReader.read { db in
            try DBConnectionEnablement.fetchAll(db).compactMap { row in
                guard let kind = ConnectionKind(rawValue: row.kind),
                      let capability = ConnectionCapability(rawValue: row.capability) else {
                    return nil
                }
                return Enablement(kind: kind, capability: capability, conversationId: row.conversationId)
            }
        }) ?? []
    }

    public func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool {
        (try? await dbReader.read { db in
            try DBConnectionAlwaysConfirm
                .filter(DBConnectionAlwaysConfirm.Columns.kind == kind.rawValue)
                .filter(DBConnectionAlwaysConfirm.Columns.conversationId == conversationId)
                .fetchOne(db)?.alwaysConfirm ?? false
        }) ?? false
    }

    public func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async {
        try? await dbWriter.write { db in
            if alwaysConfirm {
                try DBConnectionAlwaysConfirm(
                    kind: kind.rawValue,
                    conversationId: conversationId,
                    alwaysConfirm: true,
                    createdAt: Date(),
                    updatedAt: Date()
                ).save(db, onConflict: .replace)
            } else {
                _ = try DBConnectionAlwaysConfirm
                    .filter(DBConnectionAlwaysConfirm.Columns.kind == kind.rawValue)
                    .filter(DBConnectionAlwaysConfirm.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }
        }
    }
}

struct DBConnectionEnablement: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "connectionEnablement"

    enum Columns {
        static let kind: Column = Column(CodingKeys.kind)
        static let capability: Column = Column(CodingKeys.capability)
        static let conversationId: Column = Column(CodingKeys.conversationId)
    }

    let kind: String
    let capability: String
    let conversationId: String
    let createdAt: Date
    let updatedAt: Date
}

struct DBConnectionAlwaysConfirm: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "connectionAlwaysConfirm"

    enum Columns {
        static let kind: Column = Column(CodingKeys.kind)
        static let conversationId: Column = Column(CodingKeys.conversationId)
    }

    let kind: String
    let conversationId: String
    let alwaysConfirm: Bool
    let createdAt: Date
    let updatedAt: Date
}
