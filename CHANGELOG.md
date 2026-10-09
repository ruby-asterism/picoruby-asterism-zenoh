# Changelog

All notable changes to picoruby-asterism-zenoh. From 0.4.0 it carries the
same version number as the CRuby binding (asterism-zenoh), and the same
Ruby API for what both have.

## 0.4.0

The first step of the API review toward 1.0 (the asterism gem's
docs/api_review.md). Additions and deprecations only.

Added

- `mrblib/`: Ruby on top of the C binding. `mrblib/common.rb` is the same
  file as asterism-zenoh's `lib/asterism/zenoh/common.rb`.
- `timeout:` (seconds) and `timeout_ms:` on `get` and `liveliness_get`;
  `params:` and `payload:` on `get`; `depth:` on `subscribe`, `queryable`
  and `liveliness_watch`. Giving a time limit twice raises `ArgumentError`.
- `Session#connection_count`.
- One error tree: `Asterism::Error` > `Asterism::Zenoh::Error` >
  `Asterism::Zenoh::ClosedError` (the session is closed or its connection
  was lost); `Error#code` is zenoh-pico's result code when there was one.
- `Session.open { |s| }`; a clear `ArgumentError` for the CRuby-only
  keywords (`config:` and the rest) instead of mruby's keyword error.
- `VERSION`, `BACKEND` (`:zenoh_pico`), `BACKEND_VERSION`,
  `PEER_SUPPORTED`, `DEFAULT_TIMEOUT`.
- Each query carries its queryable's key (for the one-argument
  `Query#reply`, below).
- `Asterism.deprecated` / `Asterism.deprecations` (also
  `ASTERISM_DEPRECATIONS`).

Deprecated (each warns once per VM; removed or changed in 1.0)

- The time limit as a positional argument of `get` / `liveliness_get`; a
  Float there warns with its own message (it is milliseconds, truncated).
- `Session#peers`: use `connection_count`.
- `Query#reply(payload)` when the query's key differs from the queryable's
  own key and that key has no wildcard.

## 0.2.0

- Out of fmruby-core as a repository of its own: sessions (client, peer,
  listening), put / subscribe, get / queryable with attachments, target and
  consolidation, liveliness tokens, watches and get, a host test on CI.
  (The version of the API it has; it was not versioned separately then.)
