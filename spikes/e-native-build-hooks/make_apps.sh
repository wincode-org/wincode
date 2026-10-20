#!/usr/bin/env bash
# Spike E: the test apps, created in scratch and never committed:
#   counter        the stock `flutter create` app (control: no hooks)
#   hooks_app      the same, plus path_provider with path_provider_foundation 2.6.0 and
#                  objective_c 9.5.0 pinned, showing getApplicationDocumentsDirectory()
#   hooks_app_251  hooks_app with path_provider_foundation 2.5.1, the last plugin-based release
#   hooks_app_bundle  hooks_app without the packages that have build hooks, only for the asset
#                  bundle: `flutter build bundle --target-platform ios` runs the hooks itself and
#                  stops on Linux ("Failed to find xcrun"); its NOTICES lack those packages
set -euo pipefail
SPIKE_E=${SPIKE_E:-$HOME/spikes/spike-e}
FLUTTER_ROOT=${FLUTTER_ROOT:-$HOME/spikes/spike-a/flutter}
export PATH="$FLUTTER_ROOT/bin:$PATH" CI=true FLUTTER_SUPPRESS_ANALYTICS=true
mkdir -p "$SPIKE_E" && cd "$SPIKE_E"

[ -d counter ] || flutter create --org dev.wincode.spike --project-name counter --platforms ios counter >/dev/null

if [ ! -d hooks_app ]; then
  flutter create --org dev.wincode.spike --project-name hooks_app --platforms ios hooks_app >/dev/null
  (cd hooks_app && flutter pub add path_provider path_provider_foundation:2.6.0 objective_c:9.5.0)
  cat > hooks_app/lib/main.dart <<'DART'
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const MaterialApp(home: DocumentsPath()));

class DocumentsPath extends StatelessWidget {
  const DocumentsPath({super.key});

  Future<Directory> _documents() async {
    final dir = await getApplicationDocumentsDirectory();
    print('spike-e documents: ${dir.path}'); // also lands in the device log
    return dir;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FutureBuilder<Directory>(
            future: _documents(),
            builder: (context, snapshot) => Text(
              snapshot.hasError
                  ? 'path_provider error: ${snapshot.error}'
                  : 'documents: ${snapshot.data?.path ?? '…'}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
DART
fi

if [ ! -d hooks_app_251 ]; then
  cp -r hooks_app hooks_app_251
  sed -i 's/^name: hooks_app$/name: hooks_app_251/' hooks_app_251/pubspec.yaml
  (cd hooks_app_251 && flutter pub remove objective_c && flutter pub add path_provider_foundation:2.5.1)
fi

if [ ! -d hooks_app_bundle ]; then
  cp -r hooks_app hooks_app_bundle
  sed -i 's/^name: hooks_app$/name: hooks_app_bundle/' hooks_app_bundle/pubspec.yaml
  (cd hooks_app_bundle && flutter pub remove path_provider path_provider_foundation objective_c)
  cp counter/lib/main.dart hooks_app_bundle/lib/main.dart
fi

for app in counter hooks_app hooks_app_251 hooks_app_bundle; do (cd "$app" && flutter pub get >/dev/null); done
for app in hooks_app hooks_app_251; do
  echo "== $app"
  (cd "$app" && flutter pub deps --style=compact | grep -E '^- (path_provider_foundation|objective_c) ' || true)
done
