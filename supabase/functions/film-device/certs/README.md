# Public Apple trust anchors

Downloaded from [Apple PKI](https://www.apple.com/certificateauthority/) on 2026-10-15. These are public CA certificates, not signing/private keys. The production Node verifier trusts only these bundled roots; tests generate an independent temporary test CA and prove its signed receipts fail against the production roots.

| File | Source | SHA-256 |
| --- | --- | --- |
| AppleIncRootCertificate.cer | https://www.apple.com/appleca/AppleIncRootCertificate.cer | b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024 |
| AppleRootCA-G2.cer | https://www.apple.com/certificateauthority/AppleRootCA-G2.cer | c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050 |
| AppleRootCA-G3.cer | https://www.apple.com/certificateauthority/AppleRootCA-G3.cer | 63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179 |

`apple-roots.mjs` embeds the same DER bytes for deployment without runtime filesystem loading. The Node tests compare every embedded certificate and fingerprint against these files. Review certificate updates explicitly against Apple PKI before replacing a trust anchor.
