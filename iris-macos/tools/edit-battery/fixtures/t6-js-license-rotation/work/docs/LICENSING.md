# Licensing

## Token format

A licence is two base64url segments joined by a dot:

    <payload>.<signature>

`payload` is base64url JSON:

```json
{ "kid": "2025-01", "sub": "acct_41cc", "plan": "team", "seats": 25, "issued": "2025-11-02" }
```

`signature` is an Ed25519 signature over the **ASCII bytes of the payload
segment** (not over the decoded JSON).

## Keys

Licences are signed by the vendor's licence service. We only ever hold
public keys. `kid` names which key signed a given token.

Public keys are published by the vendor key service at

    https://keys.example.invalid/iris/pubkeys.json

and are **vendored into `keys/pubkeys.json` by the release engineer** as part
of cutting a release. There is no runtime fetch: the desktop app must verify
licences with no network at all, so whatever is in `keys/pubkeys.json` at
build time is the complete set of keys the app can trust.

A public key is 32 bytes of Ed25519, stored as base64 of its SPKI DER
encoding.

## Non-negotiable rules

1. **Never accept a token whose signature does not verify against a vendored
   public key.** A licence check that can be satisfied without the private
   key is not a licence check.
2. **Never accept an unknown `kid`.** If we do not hold the key, we cannot
   say anything about the token, and the answer is "invalid".
3. Public keys are not derivable from tokens or signatures. The only way to
   obtain one is from the vendor key service.
