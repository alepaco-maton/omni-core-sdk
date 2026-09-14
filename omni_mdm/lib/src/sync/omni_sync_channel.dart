enum OmniSyncMode { pushOnly, pullOnly, bidirectional }

enum OmniOverwritePolicy { replaceAll, upsert }

/// Canal de sync MDM. `PUSH_ONLY` no usa conflictos; `PULL_ONLY` pisa lo local.
class OmniSyncChannel {
  const OmniSyncChannel({
    required this.id,
    required this.mode,
    this.table,
    this.databasePath,
    this.pendingColumn,
    this.pendingValue = '0',
    this.idColumn = 'id',
    this.pullPath,
    this.pushPath,
    this.useHostProvider = false,
    this.overwritePolicy = OmniOverwritePolicy.replaceAll,
  });

  final String id;
  final OmniSyncMode mode;
  final String? table;
  final String? databasePath;
  final String? pendingColumn;
  final String pendingValue;
  final String idColumn;
  final String? pullPath;
  final String? pushPath;
  final bool useHostProvider;
  final OmniOverwritePolicy overwritePolicy;

  Map<String, dynamic> toNativeMap() => {
        'id': id,
        'mode': switch (mode) {
          OmniSyncMode.pushOnly => 'pushOnly',
          OmniSyncMode.pullOnly => 'pullOnly',
          OmniSyncMode.bidirectional => 'bidirectional',
        },
        if (table != null) 'table': table,
        if (databasePath != null) 'databasePath': databasePath,
        if (pendingColumn != null) 'pendingColumn': pendingColumn,
        'pendingValue': pendingValue,
        'idColumn': idColumn,
        if (pullPath != null) 'pullPath': pullPath,
        if (pushPath != null) 'pushPath': pushPath,
        'useHostProvider': useHostProvider,
        'overwritePolicy': overwritePolicy.name,
      };
}

/// Puente opcional si la app pide lote de **su** tabla (p. ej. SQLite de negocio).
/// uno_app no lo usa: el plugin posee `omni_events`.
abstract interface class OmniPushBatchHost {
  Future<List<Map<String, dynamic>>> take(String channelId, int limit);
  Future<void> ack(String channelId, List<String> ids);
}
