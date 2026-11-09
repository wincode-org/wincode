import 'dart:convert';
import 'dart:typed_data';

import 'plist.dart';

/// What winCode reads in a provisioning profile (`.mobileprovision`): the property list that Apple signed. The CMS
/// signature around it is not checked, as the spike's `sign.py` did not check it.
class ProvisioningProfile {
  const ProvisioningProfile({
    required this.uuid,
    required this.teamId,
    required this.applicationIdentifier,
    required this.expirationDate,
    required this.isForAppStore,
  });

  /// `UUID`: what App Store Connect calls the profile's `uuid`, and what the signed app's embedded copy carries.
  final String uuid;

  /// The first of `TeamIdentifier`: the team that made the profile.
  final String teamId;

  /// The `application-identifier` the profile allows, `<team ID>.<bundle ID>`, or with a trailing `*` for a wildcard
  /// App ID.
  final String applicationIdentifier;

  /// `ExpirationDate`, in UTC.
  final DateTime expirationDate;

  /// Whether it is an App Store distribution profile: it lists no devices (development and ad hoc profiles do), does
  /// not provision every device (enterprise profiles do), and does not allow `get-task-allow` (development).
  final bool isForAppStore;
}

/// Reads the profile [bytes], as the developer portal delivers it. Throws a [FormatException] when it holds no property
/// list, or one without the team, the application identifier or the expiry date.
ProvisioningProfile readProvisioningProfile(Uint8List bytes) {
  // ponytail: the property list is found by its first and last markers inside the CMS, not by parsing the CMS. A profile
  // whose content is split into chunks would fail here, closed; parse the CMS if one ever does.
  final text = latin1.decode(bytes);
  final start = text.indexOf('<?xml');
  final end = start < 0 ? -1 : text.indexOf('</plist>', start);
  if (end < 0) {
    throw const FormatException('it holds no property list');
  }
  final Object? plist;
  try {
    plist = parsePlist(
      utf8.decode(Uint8List.sublistView(bytes, start, end + '</plist>'.length)),
    );
  } on FormatException {
    throw const FormatException('its property list cannot be read');
  }
  if (plist
      case final Map<String, Object?> profile &&
          {
            'UUID': final String uuid,
            'TeamIdentifier': [final String teamId, ...],
            'Entitlements':
                final Map<String, Object?> entitlements &&
                {'application-identifier': final String appId},
            'ExpirationDate': final DateTime expires,
          }) {
    return ProvisioningProfile(
      uuid: uuid,
      teamId: teamId,
      applicationIdentifier: appId,
      expirationDate: expires.toUtc(),
      isForAppStore:
          !profile.containsKey('ProvisionedDevices') &&
          profile['ProvisionsAllDevices'] != true &&
          entitlements['get-task-allow'] != true,
    );
  }
  throw const FormatException(
    'its property list lacks UUID, TeamIdentifier, the application-identifier entitlement or ExpirationDate',
  );
}
