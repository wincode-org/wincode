# wincode_asc

Dart library: the App Store Connect API client of winCode ([ADR-0013](../../docs/adr/0013-wincode-cli-build-sign-upload.md), section 5). It holds the API token and the read requests that `wincode preflight` sends; build uploads come in phase 4.

- **`AscKey`** reads the `.p8` as App Store Connect delivers it (PKCS #8, EC P-256) and makes the ES256 token that Apple documents: header `alg`, `kid`, `typ`; claims `iss`, `iat`, `exp` (10 minutes later) and `aud`. Signatures are deterministic (RFC 6979), and the test checks them against the RFC's P-256 and SHA-256 vectors, so it does not rely on the library that signs. Neither its messages nor its `toString` show the key.
- **`HttpAscClient.getAll`** sends GET requests only, to `api.appstoreconnect.apple.com` only, and follows `links.next` while it stays on that host. Each request gets a new token, and a redirect is not followed. A request that gets no answer within 20 seconds, cannot connect, or gets HTTP 5xx is tried twice more, after 1 and 2 seconds; nothing else is retried. `HTTPS_PROXY` and `NO_PROXY` apply. The `log` gets one line per attempt, never the token or a header.
- **`package:wincode_asc/testing.dart`**, for tests only: a throwaway P-256 key, and a fake App Store Connect on 127.0.0.1 that answers in Apple's shapes with made-up IDs.

Dependency: `pointycastle` 4.0.0 (MIT), pinned to that exact version because it signs with the user's key. Only `AscKey.sign` calls it, so it can be replaced behind that function.

## Tests

```
dart test
```

No test reaches the network.
