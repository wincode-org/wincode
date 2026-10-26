import 'build_settings.dart';
import 'plist.dart';

/// The entitlements the app's executable is signed with (ADR-0011 rule 6): the app's own `.entitlements` file, with its
/// variables replaced, merged with `application-identifier`, `com.apple.developer.team-identifier`,
/// `get-task-allow` = false and the app's own keychain group.
///
/// `$(AppIdentifierPrefix)` becomes `<teamId>.`. [own] is the parsed file, or empty when the app has none. The caller
/// checks every key and value against the provisioning profile before signing.
PlistMap buildEntitlements({
  required PlistMap own,
  required BuildSettings settings,
  required String teamId,
}) {
  final bundleId = settings['PRODUCT_BUNDLE_IDENTIFIER'];
  if (bundleId == null || bundleId.isEmpty) {
    throw const FormatException('PRODUCT_BUNDLE_IDENTIFIER is not set');
  }
  final appId = '$teamId.$bundleId';
  final extra = {
    'AppIdentifierPrefix': '$teamId.',
    'CFBundleIdentifier': bundleId,
  };
  Object? expand(Object? v) => switch (v) {
    final String s => settings.expand(s, strict: true, extra: extra),
    final List<Object?> l => [for (final x in l) expand(x)],
    final Map<Object?, Object?> m => {
      for (final e in m.entries) e.key! as String: expand(e.value),
    },
    _ => v,
  };
  final result = expand(own) as PlistMap;
  final groups = <String>{
    ...((result['keychain-access-groups'] as List<Object?>?) ?? const [])
        .cast<String>(),
    appId,
  };
  return {
    ...result,
    'application-identifier': appId,
    'com.apple.developer.team-identifier': teamId,
    'get-task-allow': false,
    'keychain-access-groups': groups.toList(),
  };
}
