# formats

Specifications of Apple file formats (for example `Assets.car`), written from observed outputs only. Implementations are written from these specs, never from Apple software. See CONTRIBUTING.md.

Status: the Mach-O conformance check and the entitlements read-back are implemented in `packages/wincode_core`; nothing of `Assets.car` is.

| File | Format | State |
| --- | --- | --- |
| [assets-car-app-icon.md](assets-car-app-icon.md) | `Assets.car`, app icon | A-side observations from run 39513689791 |
| [macho-conformance.md](macho-conformance.md) | Mach-O load commands and chained fixups, SDK text stubs (`.tbd`) | Design of the conformance check, from public LLVM references |
| [code-signature-entitlements.md](code-signature-entitlements.md) | The entitlements blob of a Mach-O code signature | Read by `wincode preflight`, from Apple's open-source headers |
