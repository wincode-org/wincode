# Code signature: what `wincode sign` checks after zsign

Status: format notes, 2026-11-11, for the read-back of ADR-0013 phase 3a. `wincode sign` and `wincode sign --verify-only` check every signature of an IPA that zsign signed. winCode only reads signatures: zsign writes them (ADR-0013, section 4). [code-signature-entitlements.md](code-signature-entitlements.md) covers where the signature is and the SuperBlob around it; this file covers the rest.

Every integer of a signature is big-endian. Every integer of a Mach-O header or load command is little-endian (arm64).

## Which files are Mach-O files

A file of the bundle is a Mach-O file when its first four bytes, read little-endian, are 0xFEEDFACE or 0xFEEDFACF (32- and 64-bit) or their byte-swapped forms, or when read big-endian they are 0xCAFEBABE (a fat file). zsign uses this rule and skips paths that contain `.dSYM` or `_WatchKitStub`; so does winCode.

A fat file starts with `nfat_arch` (big-endian, at offset 4) entries of 20 bytes from offset 8: `cputype`, `cpusubtype`, `offset`, `size`, `align`, each big-endian. Each slice at `offset` is a Mach-O file of its own, and each carries its own signature. The 64-bit fat header (0xCAFEBABF) is refused: zsign does not write it.

A thin Mach-O header is 28 bytes (32-bit) or 32 bytes (64-bit); `ncmds` is at offset 16. The signature is where `LC_CODE_SIGNATURE` points (`dataoff`, `datasize`), relative to the start of the slice.

## The code directory (slot 0, magic 0xFADE0C02)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic |
| 4 | 4 | length |
| 8 | 4 | version: 0x20400 from zsign 1.9.0 |
| 12 | 4 | flags: 0 for a signature with a certificate |
| 16 | 4 | `hashOffset`: where the hash of page 0 starts, from the start of the code directory |
| 20 | 4 | `identOffset`: a NUL-terminated identifier |
| 24 | 4 | `nSpecialSlots` |
| 28 | 4 | `nCodeSlots` |
| 32 | 4 | `codeLimit`: how many bytes of the slice the page hashes cover |
| 36 | 1 | `hashSize`: 20 or 32 |
| 37 | 1 | `hashType`: 1 SHA-1, 2 SHA-256 |
| 38 | 1 | `platform` |
| 39 | 1 | `pageSize`: log2 of the page size, 12 (4096 bytes) |
| 40 | 4 | spare |
| 44 | 4 | `scatterOffset` (version 0x20100 and later), 0 |
| 48 | 4 | `teamOffset` (0x20200 and later): a NUL-terminated team ID |
| 52 | 4 | spare |
| 56 | 8 | `codeLimit64` (0x20300 and later), 0 when `codeLimit` holds the limit |
| 64 | 8 × 3 | `execSegBase`, `execSegLimit`, `execSegFlags` (0x20400 and later) |

The code slots: `nCodeSlots` hashes of `hashSize` bytes from `hashOffset`. Slot *i* is the hash of the bytes `[i × page, min((i + 1) × page, codeLimit))` of the slice, so the last page may be short. `nCodeSlots` is `ceil(codeLimit / page)`. zsign sets `codeLimit` to `dataoff` of `LC_CODE_SIGNATURE`: everything before the signature is hashed.

The special slots: `nSpecialSlots` hashes just before `hashOffset`, slot −*n* at `hashOffset − n × hashSize`. A slot that is missing (beyond `nSpecialSlots`) or all zeros means that the item is absent. zsign drops trailing absent slots.

| Slot | Hash of |
| --- | --- |
| −1 | the bundle's `Info.plist`, as a file |
| −2 | the requirements blob (slot 2), magic and length included |
| −3 | the bundle's `_CodeSignature/CodeResources`, as a file |
| −4 | unused, absent |
| −5 | the XML entitlements blob (slot 5), magic and length included |
| −6 | unused, absent |
| −7 | the DER entitlements blob (slot 7), magic and length included |

zsign 1.9.0 writes one code directory, with SHA-256, by default (`-L` adds a SHA-1 one first, in slot 0, and puts the SHA-256 one in slot 0x1000, the first alternate code directory). Each code directory has its own hashes of the same items, with its own hash type. Slots 0x1000 to 0x1004 are alternate code directories.

### What zsign puts in each item

- **Identifier:** for a bundle's executable (`CFBundleExecutable` of a folder whose `Info.plist` has `CFBundleIdentifier` and `CFBundleExecutable`: the app, and each `.framework`), the bundle's `CFBundleIdentifier`. For any other Mach-O file, the `CFBundleIdentifier` of an Info.plist embedded in its `__TEXT,__info_plist` section if it has one, else the file's name. winCode accepts only the file's name for those: a file with an embedded Info.plist fails, closed.
- **Team ID:** the profile's `TeamIdentifier[0]`, for every file.
- **Info.plist slot:** set for a bundle's executable; absent for other files (or the embedded Info.plist's hash, which winCode does not accept).
- **Resource slot:** set for a bundle's executable; absent for other files.
- **Entitlements:** a file of type `MH_EXECUTE` (the app's executable) gets the entitlements it was given, as XML in slot 5 and as DER in slot 7. Every other file gets an empty dictionary in slot 5 and no slot 7. The DER slots (−6, −7) exist only for an `MH_EXECUTE` file.
- **Requirements (slot 2, magic 0xFADE0C01):** always written; winCode checks only its hash.

## The DER entitlements (slot 7, magic 0xFADE7172)

After the 8-byte header, X.690 DER: `[APPLICATION 16] { INTEGER 1, value }` (tag 0x70), where a value is a dictionary `[CONTEXT 16] { SEQUENCE { UTF8String key, value }... }` (tag 0xB0, keys sorted), an array `SEQUENCE { value... }` (0x30), a UTF8String (0x0C), a BOOLEAN (0x01, 0xFF true) or an INTEGER (0x02). winCode decodes it and compares the result with the XML entitlements of slot 5; they must be equal. zsign 1.9.0 writes an integer's value as its own length, which is right only for the value 1: entitlements with another integer cannot be signed in agreement, and the check fails, closed. An app's entitlements hold strings, booleans and arrays of strings.

## The CMS signature (slot 0x10000, magic 0xFADE0B01)

After the 8-byte header, a DER `ContentInfo` of type `signedData` (1.2.840.113549.1.7.2), RFC 5652, as OpenSSL's `CMS_sign` writes it with `CMS_DETACHED | CMS_BINARY | CMS_NOSMIMECAP | CMS_PARTIAL`:

- `encapContentInfo` is of type `data` (1.2.840.113549.1.7.1) with no content: the signed content is the code directory of slot 0, as bytes.
- `certificates` holds the signing certificate, its issuer and the root.
- One `SignerInfo`: `sid` is the issuer and serial number of the signing certificate; `digestAlgorithm` is SHA-256 (2.16.840.1.101.3.4.2.1); `signedAttrs` hold `contentType` (`data`), `signingTime`, `messageDigest` (SHA-256 of the code directory of slot 0), Apple's `cdhashes` (1.2.840.113635.100.9.1: an OCTET STRING holding an XML property list `{cdhashes: [data, ...]}`, one entry per code directory in slot order, each the first 20 bytes of that code directory's hash with its own hash type) and Apple's second hash attribute (1.2.840.113635.100.9.2); `signature` is RSA PKCS #1 v1.5 with SHA-256 over the DER of `signedAttrs`, with its tag set to SET (0x31) as RFC 5652, section 5.4, says.

The chosen certificate is the profile's certificate of the distribution key in `wincode sign`. `wincode sign --verify-only` has no key: it takes the certificate of `certificates` whose issuer and serial number are the `sid` of the app executable's signer (the first slice of a fat file), and requires it to be one of the profile's `DeveloperCertificates`, byte for byte.

winCode checks: one signer; its issuer and serial number are those of the chosen certificate, which is in `certificates` byte for byte; `messageDigest` and `cdhashes` match the code directories; the RSA signature verifies with the chosen certificate's public key. It does not check 1.2.840.113635.100.9.2, the signing time or the chain to Apple's root: App Store Connect checks the chain when it processes the upload.

## `_CodeSignature/CodeResources`

An XML property list per bundle (the app and each `.framework` with an `Info.plist`), written by zsign as follows:

- `files2`: for every file under the bundle, by its path relative to the bundle, `{hash: <SHA-1>, hash2: <SHA-256>}` as `<data>`, with `optional: true` for a path under a `.lproj/`. Left out: the bundle's own executable, its own `_CodeSignature/CodeResources`, `Info.plist`, `PkgInfo`, `.DS_Store` files and `.lproj/locversion.plist`. The files of a nested bundle are listed one by one, its executable and its `CodeResources` included: zsign writes no `nested` entries with a code directory hash.
- `files`: the same paths except that `Info.plist` and `PkgInfo` are in, each `<data>` with the SHA-1, or `{hash, optional: true}` under a `.lproj/`.
- `rules` and `rules2`: zsign's fixed rules, which match what it listed.

winCode checks that `files2` names exactly the files that zsign would list, each with the right `hash2` and `hash`, and that `files` names exactly its own list with the right SHA-1.

## The profile

zsign writes the profile file it is given, byte for byte, as `embedded.mobileprovision` at the top of the app. winCode compares the bytes with the configured profile.

## Not covered

- An app with extensions (`.appex`) or a watch app: `wincode sign` refuses them before signing, because each needs its own profile.
- A loose Mach-O file with an embedded Info.plist (see Identifier).
- The chain of trust of the CMS signature, its signing time, and the requirements' content.

## Provenance

- The code directory, the slots, the magics and the hash types: `osfmk/kern/cs_blobs.h` in Apple's open-source xnu.
- The fat header: `mach-o/fat.h` (cctools, xnu), and LLVM's `llvm/BinaryFormat/MachO.h`.
- CMS: RFC 5652. X.509: RFC 5280. RSA PKCS #1 v1.5: RFC 8017. DER: ITU-T X.690.
- What zsign writes, and where: the source of zsign 1.9.0 (MIT), commit `f6158be9e62a5ce2a53d72b1a6d880880da956c8`, read in `src/archo.cpp` (`BuildCodeSignature`), `src/signing.cpp` (`SlotBuildCodeDirectory`, `SlotBuildCMSSignature`, `_DER`), `src/openssl.cpp` (`GenerateCMS`), `src/bundle.cpp` (`GenerateCodeResources`, `GetObjectsToSign`) and `src/zsign.cpp`.
- Observed: build 13 of the test app, signed by the spike's `sign.py` with that zsign and installed from TestFlight, passes every check above.
- No Apple tool or framework was decompiled or disassembled. The tests build their Mach-O files, certificates, profiles and signatures in code.
