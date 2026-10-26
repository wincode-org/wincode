import 'dart:io';

import 'openstep.dart';
import 'xcconfig.dart';

final _variable = RegExp(r'\$[({]([A-Za-z0-9_]+)(?::([A-Za-z0-9_]+))?[)}]');
final _inherited = RegExp(r'\$[({]inherited[)}]');

/// The build settings of one target in one configuration, as Xcode layers them (lowest first): built-in defaults,
/// the project's xcconfig, the project's settings, the target's xcconfig, the target's settings.
///
/// Values stay unexpanded until they are read; `$(NAME)` and `${NAME}` are replaced then, with the modifiers
/// `c99extidentifier`, `identifier`, `rfc1034identifier`, `lower` and `upper`.
class BuildSettings {
  BuildSettings(Map<String, String> values)
    : _values = Map.unmodifiable(values);

  final Map<String, String> _values;

  Iterable<String> get keys => _values.keys;

  bool containsKey(String key) => _values.containsKey(key);

  /// The expanded value of [key], or null when it isn't set.
  String? operator [](String key) =>
      _values.containsKey(key) ? expand(_values[key]!) : null;

  /// Replaces every `$(NAME)` in [input]. An unknown name gives an empty string, or with [strict] an error
  /// (ADR-0011 rule 2: `unknown Info.plist variable $(NAME)`). [extra] holds names that exist only here.
  String expand(
    String input, {
    bool strict = false,
    Map<String, String> extra = const {},
    int depth = 0,
  }) {
    if (depth > 20) {
      throw FormatException(
        'build settings refer to each other in a loop: $input',
      );
    }
    return input.replaceAllMapped(_variable, (m) {
      final name = m.group(1)!;
      final raw = extra[name] ?? _values[name];
      if (raw == null) {
        if (strict) {
          throw FormatException(
            r'unknown variable $('
            '$name)',
          );
        }
        return '';
      }
      return _modify(
        expand(raw, strict: strict, extra: extra, depth: depth + 1),
        m.group(2),
      );
    });
  }
}

String _modify(String value, String? modifier) {
  switch (modifier) {
    case null:
      return value;
    case 'lower':
      return value.toLowerCase();
    case 'upper':
      return value.toUpperCase();
    case 'rfc1034identifier':
      return value.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-');
    case 'identifier':
    case 'c99extidentifier':
      final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
      return RegExp(r'^[0-9]').hasMatch(cleaned) ? '_$cleaned' : cleaned;
  }
  throw FormatException('unsupported build setting modifier :$modifier');
}

/// The settings that Xcode itself provides and an `Info.plist` template uses.
Map<String, String> _defaults(
  String target,
  String project,
  String configuration,
  String sourceRoot,
) => {
  'TARGET_NAME': target,
  'PROJECT_NAME': project,
  'CONFIGURATION': configuration,
  'SRCROOT': sourceRoot,
  'DEVELOPMENT_LANGUAGE': 'en',
  'EXECUTABLE_NAME': r'$(PRODUCT_NAME)',
  'PRODUCT_MODULE_NAME': r'$(PRODUCT_NAME:c99extidentifier)',
};

/// Reads the settings of [target] in [configuration] (for example `Release-demo`) from the Xcode project in [iosDir].
///
/// [generated] stands for Flutter's `Generated.xcconfig`, which only exists on the Mac that builds: the
/// `FLUTTER_*` settings that the project's xcconfig files include.
BuildSettings resolveBuildSettings({
  required Directory iosDir,
  required String configuration,
  String target = 'Runner',
  Map<String, String> generated = const {},
}) {
  final projectFile = File('${iosDir.path}/Runner.xcodeproj/project.pbxproj');
  final root =
      parseOpenStep(projectFile.readAsStringSync()) as Map<String, Object?>;
  final objects = root['objects']! as Map<String, Object?>;
  Map<String, Object?> object(Object? id) =>
      objects[id]! as Map<String, Object?>;

  final project = object(root['rootObject']);
  final targetId = (project['targets']! as List<Object?>).firstWhere(
    (id) => object(id)['name'] == target,
    orElse: () =>
        throw FormatException('the project has no target named $target'),
  );
  final parents = <Object?, Object?>{
    for (final entry in objects.entries)
      if (entry.value is Map && (entry.value! as Map)['children'] is List)
        for (final child in (entry.value! as Map)['children']! as List<Object?>)
          child: entry.key,
  };

  String pathOf(Object? id) {
    final segments = <String>[];
    for (Object? current = id; current != null;) {
      final o = object(current);
      final path = o['path'] as String?;
      if (path != null) segments.insert(0, path);
      final tree = o['sourceTree'];
      if (tree == '<absolute>') {
        return segments.join('/');
      }
      current = tree == '<group>' ? parents[current] : null;
    }
    return segments.join('/');
  }

  Map<String, Object?> configurationOf(Object? listId) {
    final list = object(listId);
    final configurations = (list['buildConfigurations']! as List<Object?>)
        .map(object)
        .toList();
    return configurations.firstWhere(
      (c) => c['name'] == configuration,
      orElse: () => throw FormatException(
        'configuration $configuration not found; the project has: ${configurations.map((c) => c['name']).join(', ')}',
      ),
    );
  }

  final settings = <String, String>{};
  final virtual = {
    'Generated.xcconfig': generated.entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n'),
  };

  void apply(String key, List<String> conditions, String value) {
    // Only the iPhone device matters: skip settings that apply to the simulator, a Mac or another architecture.
    for (final condition in conditions) {
      final parts = condition.split('=');
      final ok = switch (parts[0]) {
        'sdk' => parts[1] == '*' || parts[1].startsWith('iphoneos'),
        'arch' => parts[1] == '*' || parts[1] == 'arm64',
        'config' => parts[1] == configuration,
        _ => false,
      };
      if (!ok) {
        return;
      }
    }
    settings[key] = value.replaceAll(_inherited, settings[key] ?? '').trim();
  }

  void applyXcconfig(Map<String, Object?> config) {
    final ref = config['baseConfigurationReference'];
    if (ref == null) {
      return;
    }
    final file = File('${iosDir.path}/${pathOf(ref)}');
    final entries = readXcconfig(file, virtualFiles: virtual);
    for (final e in entries.where((e) => e.conditions.isEmpty)) {
      apply(e.key, e.conditions, e.value);
    }
    for (final e in entries.where((e) => e.conditions.isNotEmpty)) {
      apply(e.key, e.conditions, e.value);
    }
  }

  void applyBuildSettings(Map<String, Object?> config) {
    final raw = (config['buildSettings'] as Map<String, Object?>?) ?? const {};
    String text(Object? v) => v is List ? v.join(' ') : '$v';
    // A conditional setting (`KEY[sdk=iphoneos*]`) is more specific, so it goes after the plain ones.
    final plain = raw.entries.where((e) => !e.key.contains('['));
    final conditional = raw.entries.where((e) => e.key.contains('['));
    for (final e in [...plain, ...conditional]) {
      final at = e.key.indexOf('[');
      final key = at < 0 ? e.key : e.key.substring(0, at);
      final conditions = at < 0
          ? <String>[]
          : RegExp(r'\[([^\]]*)\]')
                .allMatches(e.key.substring(at))
                .map((m) => m.group(1)!)
                .toList();
      apply(key, conditions, text(e.value));
    }
  }

  settings.addAll(
    _defaults(target, 'Runner', configuration, iosDir.absolute.path),
  );
  final projectConfig = configurationOf(project['buildConfigurationList']);
  final targetConfig = configurationOf(
    object(targetId)['buildConfigurationList'],
  );
  applyXcconfig(projectConfig);
  applyBuildSettings(projectConfig);
  applyXcconfig(targetConfig);
  applyBuildSettings(targetConfig);
  return BuildSettings(settings);
}
