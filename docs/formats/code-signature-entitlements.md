# Code signature: the entitlements a binary is signed with

Status: format notes, 2026-11-09. `wincode preflight` reads the entitlements of a signed app's main executable (ADR-0013, phase 2), and `wincode sign` will read every binary back after zsign (phase 3). winCode reads signatures only: zsign writes them (ADR-0013, section 4).

## Where the signature is

The load command `LC_CODE_SIGNATURE` (`cmd` 0x1D) is a `linkedit_data_command` of 16 bytes: `cmd`, `cmdsize`, `dataoff` and `datasize`, each a little-endian 32-bit integer, like every load command of an arm64 Mach-O. The signature is the `datasize` bytes at the file offset `dataoff`, at the end of `__LINKEDIT`. A file without this command is not signed.

## The embedded signature

Every integer of the signature is big-endian. It is a SuperBlob:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic, 0xFADE0CC0 (an embedded signature) |
| 4 | 4 | length of the whole SuperBlob |
| 8 | 4 | count, the number of blobs |
| 12 | 8 × count | the index: for each blob, its slot type (4 bytes), then its offset from the start of the SuperBlob (4 bytes) |

Each blob starts with its own magic (4 bytes) and its length (4 bytes, these 8 bytes included). Slots that an app's signature can hold, from `cs_blobs.h`:

| Slot type | Blob | Magic |
| --- | --- | --- |
| 0 | the code directory: the hashes of the code pages | 0xFADE0C02 |
| 2 | the requirements | 0xFADE0C01 |
| 5 | the entitlements, as an XML property list | 0xFADE7171 |
| 7 | the same entitlements, in DER | 0xFADE7172 |
| 0x10000 | the CMS signature, in a wrapper | 0xFADE0B01 |

## What winCode reads

The blob of slot 5: its magic must be 0xFADE7171, and the bytes after its 8-byte header, up to its length, are an XML property list whose top level is a dictionary. A signature without slot 5 carries no entitlements, as each framework of an app does. The other slots are skipped: their hashes and the CMS signature are not checked, so this tells what a binary claims, not that its signature is valid.

## Not covered here

- Fat files: the main executable of an App Store build has one architecture, arm64. A fat file is refused.
- Checking the code directory's hashes, the requirements, the DER entitlements of slot 7 or the CMS signature: `wincode sign` does, see [code-signature-verification.md](code-signature-verification.md).

## Provenance

- `LC_CODE_SIGNATURE` and `linkedit_data_command`: `mach-o/loader.h`, published by Apple as open source (cctools, xnu), and LLVM's `llvm/BinaryFormat/MachO.h`.
- The SuperBlob, the magics and the slot types: `osfmk/kern/cs_blobs.h` in Apple's open-source xnu, and the source of zsign (MIT), which writes them. `tools/ipa-diff` reads the entitlements blob the same way.
- Observed: in spike C, `sign.py` read every binary of each IPA that zsign signed back with `tools/ipa-diff`. The main executable carried slot 5 with exactly the entitlements it was given, and every framework carried none.
- No Apple tool or framework was decompiled or disassembled. The tests build their Mach-O files and signatures in code.
