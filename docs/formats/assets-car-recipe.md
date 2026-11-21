# Assets.car: the `actool` invocations Xcode makes

## A-side observations

Clean-room rule (CONTRIBUTING.md): this file holds what the A side observes in the outputs of Apple's tools, run on Apple hardware. It never looks inside the tools themselves. It holds command lines and output files only. Paths are placeholders (below).

### The run

- **Run 44903169894** (2026-11-21, 3 min 4 s) of `.github/workflows/oracle-reference-builds.yml` as pull request 43 extends it (steps "Probe catalog", "Probe A", "Probe B" and "Save the actool lines ..."), in a private repository, on `macos-26`.
- **Versions** (`versions.txt`): macOS 26.7.2 (25G332), arm64; Xcode 26.6 (build 17F113); iphoneos SDK 26.5; `actool` 26.6 (bundle version 24765); Flutter 3.47.7 (Dart 3.13.5). The two earlier oracle runs were on macOS 26.6.2 (25G83) with the same Xcode, SDK and `actool`.
- **How Xcode was driven:** `flutter build ios --release --no-codesign -v` (`xcodebuild`, action `build`, configuration Release, iphoneos) for the apps, and `xcodebuild -scheme ProbePackage -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO build` for the plain package. The build logs print every command line; the lines below are copied from them.
- **Recorded** (artifact `xcode-dumps`, folder `capture/`): the two probes' build logs, `<build>.actool.txt` (each line that holds `/actool `, with the two lines before it), `assets-car-files.txt` (size and SHA-256 of every `Assets.car` the builds made), `assetutil-<file>.json` (`xcrun assetutil --info`), `summary.txt`.

### The inputs

- **App catalog:** `ios/Runner/Assets.xcassets` as `flutter create` (Flutter 3.47.7) writes it: an app icon set `AppIcon` (Flutter's template artwork) and an image set `LaunchImage` (1 x 1 px at 1x, 2x and 3x). Three apps were built (the stock app, one with two plugins, and the probe app below), each with the catalog that `flutter create` wrote; their compiled catalogs are byte-identical (see "The files").
- **Package catalog (the probe):** `Assets.xcassets` with `Contents.json` and one image set `ProbeImage.imageset` (`probe@2x.png`, idiom `universal`, scale 2x). The PNG is an 8 x 8 RGBA image that the workflow generates (75 bytes): no art, no text. It is a resource, `.process("Assets.xcassets")`, of:
  - **probe A:** a Flutter plugin's Swift package, built into a generated app by Flutter (the path a package's catalog takes in a real app);
  - **probe B:** a plain Swift package that declares `.iOS(.v15)`, built by `xcodebuild` for iOS.

### What Xcode runs

Placeholders: `<xcode>` is `/Applications/Xcode_26.6.app/Contents/Developer`; `<catalog>` is the `.xcassets` folder; `<thinned>` is Xcode's scratch folder `<intermediates>/assetcatalog_output/thinned`; `<dependencies-thinned>`, `<info-plist-thinned>`, `<dependencies>`, `<info-plist>`, `<symbols-swift>`, `<symbols-objc>` and `<symbols-index>` are files in Xcode's scratch folder; `<app>` is the `.app` folder in the products folder and `<products>` is the products folder.

**For the app's catalog** (target `Runner`), in the order the log shows them:

1. `<xcode>/usr/bin/actool --version --output-format xml1`.
2. `<xcode>/usr/bin/actool --print-asset-tag-combinations --output-format xml1 <catalog>`. Once per build, for the app's catalog only. It does not run for a package's catalog (probe A), and it does not run in probe B.
3. **`GenerateAssetSymbols`:**

   ```
   actool <catalog> --compile <app> --output-format human-readable-text --notices --warnings
     --export-dependency-info <dependencies> --output-partial-info-plist <info-plist>
     --app-icon AppIcon --compress-pngs --enable-on-demand-resources YES --development-region en
     --target-device iphone --target-device ipad --minimum-deployment-target 15.0 --platform iphoneos
     --bundle-identifier <bundle id>
     --generate-swift-asset-symbols <symbols-swift> --generate-objc-asset-symbols <symbols-objc>
     --generate-asset-symbol-index <symbols-index>
   ```

   The log's `compilation-results` for it list only `<symbols-swift>`, `<symbols-objc>` and `<symbols-index>`.
4. **`CompileAssetCatalogVariant thinned`:** the invocation that makes the files (below).
5. **`LinkAssetCatalog`:** `builtin-linkAssetCatalog --thinned <thinned> --thinned-dependencies <dependencies-thinned> --thinned-info-plist-content <info-plist-thinned> --unthinned <unthinned> --unthinned-dependencies ... --unthinned-info-plist-content ... --output <app> --plist-output <info-plist>`. It is an Xcode step, not `actool`. The log then says `Emplaced <app>/Assets.car`, `<app>/AppIcon60x60@2x.png` and `<app>/AppIcon76x76@2x~ipad.png`. The folder `<unthinned>` is named but no `unthinned` compile ran in these builds.

**For a package's catalog** (target `<package>_<package>`, the resource bundle): the same `CompileAssetCatalogVariant thinned` and `LinkAssetCatalog` steps, with `--output <products>/<bundle>.bundle`, and `Emplaced <bundle>.bundle/Assets.car`. The package's library target (`<package>`) has its own `GenerateAssetSymbols`, with `--compile <products>`, no `--app-icon`, `--enable-on-demand-resources NO`, a `--bundle-identifier` that Xcode derives from the package name (`probe-assets.probe-assets` in A, `probe-package.ProbePackage` in B), and one flag more: `--generate-swift-asset-symbol-extensions NO` before `--generate-swift-asset-symbols`.

The order of these tasks differs between targets (in A, the package's `CompileAssetCatalogVariant` came before its `GenerateAssetSymbols`; in the app's target it was the other way round).

### The invocation that makes the files

Taken from `CompileAssetCatalogVariant thinned`. The flags are in the order of the log; the line breaks are added.

**App catalog** (`<thinned>` holds the results):

```
actool <catalog> --compile <thinned> --output-format human-readable-text --notices --warnings
  --export-dependency-info <dependencies-thinned>
  --output-partial-info-plist <info-plist-thinned>
  --app-icon AppIcon --compress-pngs --enable-on-demand-resources YES --development-region en
  --target-device iphone --target-device ipad --minimum-deployment-target 15.0 --platform iphoneos
```

**Package catalog:**

```
actool <catalog> --compile <thinned> --output-format human-readable-text --notices --warnings
  --export-dependency-info <dependencies-thinned>
  --output-partial-info-plist <info-plist-thinned>
  --compress-pngs --enable-on-demand-resources NO --development-region en
  --target-device iphone --target-device ipad --minimum-deployment-target 15.0 --platform iphoneos
```

- **The two differ in two places:** `--app-icon AppIcon` (app only) and the value of `--enable-on-demand-resources` (`YES` for the app, `NO` for a package).
- **Same in every context seen:** the app line was identical, apart from paths, in the three apps. The package line was identical, apart from paths, in probe A (built into an app) and probe B (built alone).
- **Not in this invocation:** `--bundle-identifier`, `--generate-swift-asset-symbols`, `--generate-objc-asset-symbols`, `--generate-asset-symbol-index` and `--generate-swift-asset-symbol-extensions` (they belong to `GenerateAssetSymbols`), and `--errors` (it is in no invocation of these logs).
- **Results the log lists for it:** for the app, `<info-plist-thinned>`, `AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png` and `Assets.car`; for a package, `<info-plist-thinned>` and `Assets.car`. One notice for the app: `76x76@1x app icons only apply to iPad apps targeting releases of iOS prior to 10.0`.
- **Where the values come from:** the log's build settings of the app show `IPHONEOS_DEPLOYMENT_TARGET = 15.0`. Probe B declares `.iOS(.v15)`. The invocation got 15.0 in both probes (the app's setting in A, the declared platform in B), and these runs do not say what a package that declares another value would get.

### The files

| File | Size | SHA-256 | Notes |
| --- | ---: | --- | --- |
| App `Assets.car` (`<app>/Assets.car`) | 66,920 | `f718b33ef4760c4e4073d4943e9688d3e4bd7147d7470ced5079cdb4b6987352` | The same bytes in the three apps. The two earlier runs gave the same size. |
| App `AppIcon60x60@2x.png` | 987 | `9d328d1d45f386375e28736159b4ffa53c4930e3962016dbf98b029a4e80121c` | A plain PNG: `IHDR` is the first chunk. |
| App `AppIcon76x76@2x~ipad.png` | 1,362 | `29a53a06908d2de7e2c0d4b50d967cc61acb33f76689c207e43f28e9724c3996` | A plain PNG. |
| Package `Assets.car` (`<bundle>.bundle/Assets.car`) | 18,248 | `e25626d6c3a80a38912aa26479ea40cc5b7455a90376d7ef9592acef68d1e4b7` | The same bytes in probe A and probe B, although the bundle, the target and the package have other names and the builds are in other folders. |

**`assetutil --info`**, app catalog: 33 entries after the header: 20 "Icon Image", 3 "Image" (`LaunchImage`, 1 x 1 px, scales 1, 2, 3), 4 "MultiSized Image" and 6 "PackedImage". The package catalog: 1 entry, an "Image" `ProbeImage`, idiom `universal`, scale 2, 8 x 8 px, `Encoding` ARGB, `Compression` deepmap2, `Opaque` true, `SizeOnDisk` 357, `NameIdentifier` 25482. The header of both:

| Field | Value |
| --- | --- |
| `Platform`, `PlatformVersion` | `ios`, `15.0` |
| `StorageVersion`, `SchemaVersion` | 17, 2 |
| `CoreUIVersion`, `DumpToolVersion` | 975, 975.2 |
| `AssetStorageVersion` | `Xcode 26.6 (17F113) via AssetCatalogSimulatorAgent` |
| `Authoring Tool` | `@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.4  [IIO-2784.5.4]` |
| `MainVersion` | `@(#)PROGRAM:CoreUI  PROJECT:CoreUI-975` |

The app's three dumps are equal except for `Timestamp`, and so are the two package dumps. **`Timestamp` is not in the file's bytes:** files with the same SHA-256 gave different values (app: 1795263576, 1795263599, 1795263626; package: 1795263616, 1795263631), all inside the run's window (2026-11-21, 12:19 to 12:20 UTC). Whether it is the file's modification time was not tested.

**Loose icon PNGs and `--compress-pngs`.** The flag was passed (the invocation above), and the two loose PNGs in `<app>` are plain PNG files. A store IPA that Xcode made elsewhere (not part of this run) has the `CgBI` chunk as the first chunk of its two loose icon PNGs. So in the `build` action the flag does not give the CgBI variant. Where that conversion happens (the `archive` action or the export, or in another tool) is not known from this run.

### What this run does not show

- **The `archive` and export actions.** Every file above comes from the `build` action. Whether `archive` runs the same invocation and gives the same `Assets.car`, and where the loose PNGs become CgBI, is open.
- **Whether `actool`, started alone with the invocation above, gives the same bytes.** Not tried. Nor whether the `--print-asset-tag-combinations` pass, the `GenerateAssetSymbols` pass, or `--compress-pngs` changes the bytes of `Assets.car` or of the PNGs.
- **Whether the same input gives the same bytes on another run, runner image or Xcode build.** Only one runner image was used, and the earlier runs recorded sizes, not the SHA-256 of `Assets.car`.
- **Other catalogs.** No vector or PDF image set, no colour set and no accent colour (the colour set of `assets-car-launch-assets.md` was compiled with another invocation), and no flag that a catalog or a build setting of that kind would add.
- **A package that declares another deployment target than the app,** and an app whose `IPHONEOS_DEPLOYMENT_TARGET` is not 15.0.
- **The `unthinned` variant.** No build ran it.
