# Changelog

## 3.2.1 — 2026-08-03
* Bumped the seat-count warning threshold.

## 3.2.0 — 2026-06-02
* **The vendor rotated its licence signing key on 2026-06-01. New licences
  carry `kid: "2026-06"`.** Vendoring the new public key into
  `keys/pubkeys.json` is still outstanding — the release engineer needs to
  pull it from the vendor key service. Tracked as SUP-2231.
* Licences issued before the rotation (`kid: "2025-01"`) are unaffected.

## 3.1.0 — 2025-11-02
* Vendored the `2025-01` public key.
* Moved verification off the network entirely.
