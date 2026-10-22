import 'database.dart';

/// Device-local remembered credentials. Never part of records, sync or backups.
/// Deliberately uses the local application profile, without OS keychain access.
class LocalCredentials {
  LocalCredentials(this.db);
  final LocalDatabase db;

  Future<String?> read({required String key}) => db.meta('credential_$key');

  Future<void> write({required String key, required String value}) =>
      db.setMeta('credential_$key', value);

  Future<void> delete({required String key}) => db.customStatement(
    'DELETE FROM metadata WHERE key=?',
    ['credential_$key'],
  );
}
