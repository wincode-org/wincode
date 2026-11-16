import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'build_project.dart';
import 'config.dart' show isFlutterVersion;

/// The update of an existing reference workflow by `wincode init --workflow` (ADR-0015, section 8). Pure functions: the
/// text of the files in, the new text and what to tell the user out.

/// The lines of the template that hold the three values the owner of a repository sets, each of which must match once.
final workflowOwnerPatterns = <String, RegExp>{
  'runs-on': RegExp(r'^(\s+runs-on: ).*$', multiLine: true),
  'timeout-minutes': RegExp(r'^(\s+timeout-minutes: ).*$', multiLine: true),
  'XCODE_APP': RegExp(r'^(\s+XCODE_APP: )\S+', multiLine: true),
};

final _xcodeApp = RegExp(r'^/Applications/[\w.\-]+\.app$');
final _label = RegExp(r'^[\w.\-]+$');

/// The new text of the workflow, and what to tell the user about the old one.
typedef WorkflowUpdate = ({
  String text,
  List<String> notes,
  String? flutterVersion,
});

/// [template] with `XCODE_APP`, `runs-on` and `timeout-minutes` of the old workflow, [old], when they are well formed.
/// A value that is not is left as the template has it, and a note says so. The old file's `FLUTTER_VERSION` is given
/// back for `wincode.yaml`, which holds the Flutter release since contract 2, and a `FLAVOR` that is not empty is
/// named in a note, since the workflow no longer holds it.
WorkflowUpdate updateWorkflow(String template, WorkflowFacts old) {
  final ours = readWorkflow(template);
  final notes = <String>[];
  final kept = <String>[];
  var text = template;

  void keep(
    String name,
    String? value,
    bool Function(String) ok,
    String ours,
    String what,
  ) {
    if (value != null && ok(value)) {
      if (value != ours) {
        text = text.replaceFirstMapped(
          workflowOwnerPatterns[name]!,
          (m) => '${m[1]}$value',
        );
        kept.add('$name $value');
      }
      return;
    }
    notes.add(
      value == null
          ? 'the old file has no $name that init can read, so the new one has $ours'
          : '$name "$value" of the old file was not kept ($what), so the new one has $ours',
    );
  }

  keep(
    'XCODE_APP',
    old.xcodeApp,
    _xcodeApp.hasMatch,
    ours.xcodeApp!,
    'it is not /Applications/<name>.app',
  );
  keep(
    'runs-on',
    old.runsOn,
    _label.hasMatch,
    ours.runsOn!,
    'it is not one runner label',
  );
  final minutes = old.timeoutMinutes;
  keep(
    'timeout-minutes',
    minutes?.toString(),
    (v) => int.parse(v) >= 1 && int.parse(v) <= 999,
    '${ours.timeoutMinutes}',
    'it is not a whole number of 1 to 999',
  );
  if (kept.isNotEmpty) {
    notes.insert(0, 'kept from the old file: ${kept.join(', ')}');
  }
  final flutter = old.flutterVersion;
  String? moved;
  if (flutter != null) {
    if (isFlutterVersion(flutter)) {
      moved = flutter;
    } else {
      notes.add(
        'FLUTTER_VERSION "$flutter" of the old file is not a Flutter release, so it was not moved to wincode.yaml',
      );
    }
  }
  final flavor = old.flavor;
  if (flavor != null && flavor.isNotEmpty) {
    notes.add(
      'the old file builds the flavor "$flavor" through FLAVOR, which the new one takes as an input: set flavor: $flavor '
      'in wincode.yaml',
    );
  }
  return (text: text, notes: notes, flutterVersion: moved);
}

/// The text of a `wincode.yaml`, [text], with `flutter_version: [version]` added, and the release that it already sets,
/// if it does (then the text is unchanged, and the file wins). A flat file gets the key at the top level, a file of
/// apps under `defaults:`, which is made when it is not there. `yaml_edit` keeps the comments and the order of the rest.
({String text, String? already}) withFlutterVersion(
  String text,
  String version,
) {
  final root = loadYaml(text) as YamlMap;
  final apps = root['apps'];
  if (apps is YamlMap) {
    final defaults = root['defaults'];
    final set = [
      if (defaults is YamlMap) defaults['flutter_version'],
      for (final app in apps.values)
        if (app is YamlMap) app['flutter_version'],
    ].nonNulls.map((v) => '$v').toList();
    if (set.isNotEmpty) return (text: text, already: set.first);
    final editor = YamlEditor(text);
    if (defaults is YamlMap) {
      editor.update(['defaults', 'flutter_version'], _plainText(version));
    } else {
      editor.update(['defaults'], {'flutter_version': _plainText(version)});
    }
    return (text: editor.toString(), already: null);
  }
  final set = root['flutter_version'];
  if (set != null) return (text: text, already: '$set');
  final editor = YamlEditor(text)
    ..update(['flutter_version'], _plainText(version));
  return (text: editor.toString(), already: null);
}

YamlNode _plainText(String v) => YamlScalar.wrap(v, style: ScalarStyle.PLAIN);
