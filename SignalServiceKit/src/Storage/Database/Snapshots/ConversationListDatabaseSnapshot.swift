//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB

@objc
public protocol ConversationListDatabaseSnapshotDelegate: AnyObject {
    func conversationListDatabaseSnapshotWillUpdate()
    func conversationListDatabaseSnapshotDidUpdate(updatedThreadIds: Set<String>)
    func conversationListDatabaseSnapshotDidUpdateExternally()
    func conversationListDatabaseSnapshotDidReset()
}

// MARK: -

@objc
public class ConversationListDatabaseObserver: NSObject {

    private var _snapshotDelegates: [Weak<ConversationListDatabaseSnapshotDelegate>] = []
    private var snapshotDelegates: [ConversationListDatabaseSnapshotDelegate] {
        AssertIsOnMainThread()
        return _snapshotDelegates.compactMap { $0.value }
    }

    @objc
    public func appendSnapshotDelegate(_ snapshotDelegate: ConversationListDatabaseSnapshotDelegate) {
        AssertIsOnMainThread()
        _snapshotDelegates = _snapshotDelegates.filter { $0.value != nil} + [Weak(value: snapshotDelegate)]
    }

    private var threadChangeCollector = ThreadChangeCollector()

    private typealias UniqueId = String
    private var committedChanges = ObservedDatabaseChanges<UniqueId>(concurrencyMode: .mainThread)

    // internal - should only be called by DatabaseStorage
    func didTouch(thread: TSThread, transaction: GRDBWriteTransaction) {
        // Note: We don't actually use the `transaction` param, but touching must happen within
        // a write transaction in order for the touch machinery to notify it's observers
        // in the expected way.
        AssertIsOnUIDatabaseObserverSerialQueue()

        threadChangeCollector.insert(thread: thread)
    }
}

extension ConversationListDatabaseObserver: DatabaseSnapshotDelegate {

    // MARK: - Transaction Lifecycle

    public func snapshotTransactionDidChange(with event: DatabaseEvent) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        if event.tableName == ThreadRecord.databaseTableName {
            threadChangeCollector.insert(rowId: event.rowID)
        }
    }

    public func snapshotTransactionDidCommit(db: Database) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        do {
            let threadChangeCollector = self.threadChangeCollector
            self.threadChangeCollector = ThreadChangeCollector()
            let committedChanges = try threadChangeCollector.threadUniqueIds(db: db)

            DispatchQueue.main.async {
                self.committedChanges.append(threadChanges: committedChanges)
            }
        } catch {
            DispatchQueue.main.async {
                self.committedChanges.setLastError(error)
            }
        }
    }

    public func snapshotTransactionDidRollback(db: Database) {
        owsFailDebug("test this if we ever use it")
        AssertIsOnUIDatabaseObserverSerialQueue()

        threadChangeCollector = ThreadChangeCollector()
    }

    // MARK: - Snapshot LifeCycle (Post Commit)

    public func databaseSnapshotWillUpdate() {
        AssertIsOnMainThread()
        for delegate in snapshotDelegates {
            delegate.conversationListDatabaseSnapshotWillUpdate()
        }
    }

    public func databaseSnapshotDidUpdate() {
        AssertIsOnMainThread()

        defer {
            self.committedChanges.reset()
        }

        let notifyReset = {
            for delegate in self.snapshotDelegates {
                delegate.conversationListDatabaseSnapshotDidReset()
            }
        }

        if let lastError = committedChanges.lastError {
            switch lastError {
            case DatabaseObserverError.changeTooLarge:
                // no assertionFailure, we expect this sometimes
                notifyReset()
            default:
                owsFailDebug("unknown error: \(lastError)")
                notifyReset()
            }
        } else {
            for delegate in snapshotDelegates {
                delegate.conversationListDatabaseSnapshotDidUpdate(updatedThreadIds: committedChanges.threadChanges)
            }
        }
    }

    public func databaseSnapshotDidUpdateExternally() {
        AssertIsOnMainThread()
        for delegate in snapshotDelegates {
            delegate.conversationListDatabaseSnapshotDidUpdateExternally()
        }
    }
}

// MARK: -

class ThreadChangeCollector {

    typealias RowId = Int64
    private var rowIds: Set<RowId> = Set()
    private var uniqueIds: Set<String> = Set()
    private var rowIdToUniqueIdMap = [RowId: String]()

    func insert(rowId: RowId) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        rowIds.insert(rowId)
    }

    func insert(thread: TSThread) {
        AssertIsOnUIDatabaseObserverSerialQueue()

        uniqueIds.insert(thread.uniqueId)

        if let grdbId = thread.grdbId {
            rowIdToUniqueIdMap[grdbId.int64Value] = thread.uniqueId
        } else {
            owsFailDebug("Missing grdbId.")
        }
    }

    func threadUniqueIds(db: Database) throws -> Set<String> {
        AssertIsOnUIDatabaseObserverSerialQueue()

        // We try to avoid the query below by leveraging the
        // fact that we know the uniqueId and rowId for
        // touched threads.
        //
        // If a thread was touched _and_ modified, we
        // can convert its rowId to a uniqueId without a query.
        var uniqueIds: Set<String> = self.uniqueIds
        var unresolvedRowIds = [RowId]()
        for rowId in rowIds {
            if let uniqueId = rowIdToUniqueIdMap[rowId] {
                uniqueIds.insert(uniqueId)
            } else {
                unresolvedRowIds.append(rowId)
            }
        }

        guard uniqueIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }
        guard unresolvedRowIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }

        guard unresolvedRowIds.count > 0 else {
            return uniqueIds
        }

        let commaSeparatedRowIds = unresolvedRowIds.map { String($0) }.joined(separator: ", ")
        let rowIdsSQL = "(\(commaSeparatedRowIds))"

        let sql = """
            SELECT \(threadColumn: .uniqueId)
            FROM \(ThreadRecord.databaseTableName)
            WHERE rowid IN \(rowIdsSQL)
        """

        let fetchedUniqueIds = try String.fetchAll(db, sql: sql)
        let allUniqueIds = uniqueIds.union(fetchedUniqueIds)

        guard allUniqueIds.count < UIDatabaseObserver.kMaxIncrementalRowChanges else {
            throw DatabaseObserverError.changeTooLarge
        }

        return allUniqueIds
    }
}
