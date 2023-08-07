/// This file is responsible for opening a suitable WASM sqlite3 database based
/// on the features available in the browsing context we're in.
///
/// The main challenge of hosting a sqlite3 database in the browser is the
/// implementation of a persistence solution. Being a C library, sqlite3 expects
/// synchronous access to a file system, which is tricky to implement with
/// asynchronous
// ignore_for_file: public_member_api_docs
@internal
library;

import 'dart:async';
import 'dart:html';

import 'package:async/async.dart';
import 'package:drift/drift.dart';
import 'package:drift/remote.dart';
import 'package:drift/wasm.dart';
import 'package:js/js.dart';
import 'package:js/js_util.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/wasm.dart';

import 'broadcast_stream_queries.dart';
import 'channel.dart';
import 'wasm_setup/protocol.dart';

/// Whether the `crossOriginIsolated` JavaScript property is true in the current
/// context.
@JS()
external bool get crossOriginIsolated;

/// Whether shared workers can be constructed in the current context.
bool get supportsSharedWorkers => hasProperty(globalThis, 'SharedWorker');

/// Whether dedicated workers can be constructed in the current context.
bool get supportsWorkers => hasProperty(globalThis, 'Worker');

class WasmDatabaseOpener {
  final Uri sqlite3WasmUri;
  final Uri driftWorkerUri;

  final String? databaseName;

  final Set<MissingBrowserFeature> missingFeatures = {};
  final List<WasmStorageImplementation> availableImplementations = [
    WasmStorageImplementation.inMemory,
  ];
  final Set<(DatabaseLocation, String)> existingDatabases = {};

  MessagePort? _sharedWorker;
  Worker? _dedicatedWorker;

  WasmDatabaseOpener(
    this.sqlite3WasmUri,
    this.driftWorkerUri,
    this.databaseName,
  );

  RequestCompatibilityCheck _createCompatibilityCheck() {
    return RequestCompatibilityCheck(databaseName ?? 'driftCompatibilityCheck');
  }

  void _handleCompatibilityResult(CompatibilityResult result) {
    missingFeatures.addAll(result.missingFeatures);

    final databaseName = this.databaseName;

    // Note that existingDatabases are only sent from workers shipped with drift
    // 2.11 or later. Later drift versions need to be able to talk to newer
    // workers though.
    if (result.existingDatabases.isNotEmpty) {
      existingDatabases.addAll(result.existingDatabases);
    }

    if (databaseName != null) {
      // If this opener has been created for WasmDatabase.open, we have a
      // database name and can interpret the opfsExists and indexedDbExists
      // fields we're getting from older workers accordingly.
      if (result.opfsExists) {
        existingDatabases.add((DatabaseLocation.opfs, databaseName));
      }
      if (result.indexedDbExists) {
        existingDatabases.add((DatabaseLocation.indexedDb, databaseName));
      }
    }
  }

  Future<WasmProbeResult> probe() async {
    try {
      await _probeShared();
    } on Object {
      _sharedWorker?.close();
      _sharedWorker = null;
    }
    try {
      await _probeDedicated();
    } on Object {
      _dedicatedWorker?.terminate();
      _dedicatedWorker = null;
    }

    return _ProbeResult(availableImplementations, existingDatabases.toList(),
        missingFeatures, this);
  }

  Future<void> _probeDedicated() async {
    if (supportsWorkers) {
      final dedicatedWorker =
          _dedicatedWorker = Worker(driftWorkerUri.toString());
      _createCompatibilityCheck().sendToWorker(dedicatedWorker);

      final workerMessages = StreamQueue(
          _readMessages(dedicatedWorker.onMessage, dedicatedWorker.onError));

      final status = await workerMessages.nextNoError
          as DedicatedWorkerCompatibilityResult;

      _handleCompatibilityResult(status);

      if (status.supportsNestedWorkers &&
          status.canAccessOpfs &&
          status.supportsSharedArrayBuffers) {
        availableImplementations.add(WasmStorageImplementation.opfsLocks);
      }

      if (status.supportsIndexedDb) {
        availableImplementations.add(WasmStorageImplementation.unsafeIndexedDb);
      }
    } else {
      missingFeatures.add(MissingBrowserFeature.dedicatedWorkers);
    }
  }

  Future<void> _probeShared() async {
    if (supportsSharedWorkers) {
      final sharedWorker =
          SharedWorker(driftWorkerUri.toString(), 'drift worker');
      final port = _sharedWorker = sharedWorker.port!;

      final sharedMessages =
          StreamQueue(_readMessages(port.onMessage, sharedWorker.onError));

      // First, the shared worker will tell us which features it supports.
      _createCompatibilityCheck().sendToPort(port);
      final sharedFeatures =
          await sharedMessages.nextNoError as SharedWorkerCompatibilityResult;
      await sharedMessages.cancel();

      _handleCompatibilityResult(sharedFeatures);

      // Prefer to use the shared worker to host the database if it supports the
      // necessary APIs.
      if (sharedFeatures.canSpawnDedicatedWorkers &&
          sharedFeatures.dedicatedWorkersCanUseOpfs) {
        availableImplementations.add(WasmStorageImplementation.opfsShared);
      }
      if (sharedFeatures.canUseIndexedDb) {
        availableImplementations.add(WasmStorageImplementation.sharedIndexedDb);
      }
    } else {
      missingFeatures.add(MissingBrowserFeature.sharedWorkers);
    }
  }
}

final class _ProbeResult implements WasmProbeResult {
  @override
  final List<WasmStorageImplementation> availableStorages;

  @override
  final List<(DatabaseLocation, String)> existingDatabases;

  @override
  final Set<MissingBrowserFeature> missingFeatures;

  final WasmDatabaseOpener opener;

  _ProbeResult(
    this.availableStorages,
    this.existingDatabases,
    this.missingFeatures,
    this.opener,
  );

  @override
  Future<DatabaseConnection> open(
    WasmStorageImplementation implementation,
    String name, {
    FutureOr<Uint8List?> Function()? initializeDatabase,
  }) async {
    final channel = MessageChannel();
    final initializer = initializeDatabase;
    final initChannel = initializer != null ? MessageChannel() : null;
    final local = channel.port1.channel();

    final message = ServeDriftDatabase(
      sqlite3WasmUri: opener.sqlite3WasmUri,
      port: channel.port2,
      storage: implementation,
      databaseName: name,
      initializationPort: initChannel?.port2,
    );

    final sharedWorker = opener._sharedWorker;
    final dedicatedWorker = opener._dedicatedWorker;

    switch (implementation) {
      case WasmStorageImplementation.opfsShared:
      case WasmStorageImplementation.sharedIndexedDb:
        // These are handled by the shared worker, so we can close the dedicated
        // worker used for feature detection.
        dedicatedWorker?.terminate();
        message.sendToPort(sharedWorker!);
      case WasmStorageImplementation.opfsLocks:
      case WasmStorageImplementation.unsafeIndexedDb:
        sharedWorker?.close();

        if (dedicatedWorker != null) {
          message.sendToWorker(dedicatedWorker);
        } else {
          // Workers seem to be broken, but we don't need them with this storage
          // mode.
          return _hostDatabaseLocally(implementation,
              await IndexedDbFileSystem.open(dbName: name), initializeDatabase);
        }
      case WasmStorageImplementation.inMemory:
        // Nothing works on this browser, so we'll fall back to an in-memory
        // database.
        return _hostDatabaseLocally(
            implementation, InMemoryFileSystem(), initializeDatabase);
    }

    initChannel?.port1.onMessage.listen((event) async {
      // The worker hosting the database is asking for the initial blob because
      // the database doesn't exist.
      Uint8List? result;
      try {
        result = await initializer?.call();
      } finally {
        initChannel.port1
          ..postMessage(result, [if (result != null) result.buffer])
          ..close();
      }
    });

    var connection = await connectToRemoteAndInitialize(local);
    if (implementation == WasmStorageImplementation.opfsLocks) {
      // We want stream queries to update for writes in other tabs. For the
      // implementations backed by a shared worker, the worker takes care of
      // that.
      // We don't enable this for unsafeIndexedDb since that implementation
      // generally doesn't support a database being accessed concurrently.
      // With the in-memory implementation, we have a tab-local database and
      // can't share anything.
      if (BroadcastStreamQueryStore.supported) {
        connection = DatabaseConnection(
          connection.executor,
          connectionData: connection.connectionData,
          streamQueries: BroadcastStreamQueryStore(name),
        );
      }
    }

    return connection;
  }

  /// Returns a database connection that doesn't use web workers.
  Future<DatabaseConnection> _hostDatabaseLocally(
    WasmStorageImplementation storage,
    VirtualFileSystem vfs,
    FutureOr<Uint8List?> Function()? initializer,
  ) async {
    final sqlite3 = await WasmSqlite3.loadFromUrl(opener.sqlite3WasmUri);
    sqlite3.registerVirtualFileSystem(vfs);

    if (initializer != null) {
      final blob = await initializer();
      if (blob != null) {
        final (file: file, outFlags: _) =
            vfs.xOpen(Sqlite3Filename('/database'), SqlFlag.SQLITE_OPEN_CREATE);
        file
          ..xWrite(blob, 0)
          ..xClose();
      }
    }

    return DatabaseConnection(
      WasmDatabase(sqlite3: sqlite3, path: '/database'),
    );
  }

  @override
  Future<void> deleteDatabase(
      DatabaseLocation implementation, String name) async {
    // TODO: implement deleteDatabase
    throw UnimplementedError();
  }
}

Stream<WasmInitializationMessage> _readMessages(
    Stream<MessageEvent> messages, Stream<Event> errors) {
  final mappedMessages = messages.map(WasmInitializationMessage.read);

  return Stream.multi((listener) {
    StreamSubscription? subscription;

    void stop() {
      subscription = null;
      listener.closeSync();
    }

    subscription = mappedMessages.listen(
      listener.addSync,
      onError: listener.addErrorSync,
      onDone: stop,
    );

    errors.first.then((value) {
      if (subscription != null) {
        listener
            .addSync(WorkerError('Worker emitted an error through onError.'));
      }
    });

    listener
      ..onCancel = () {
        subscription?.cancel();
        subscription = null;
      }
      ..onPause = subscription!.pause
      ..onResume = subscription!.resume;
  });
}

extension on StreamQueue<WasmInitializationMessage> {
  Future<WasmInitializationMessage> get nextNoError {
    return next.then((value) {
      if (value is WorkerError) {
        throw value;
      }

      return value;
    });
  }
}
