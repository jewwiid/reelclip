# ReelClips project format

Status: production format as of schema v3.

## User-visible contract

A `.reelclip` item is a document package that Files presents as one branded
document. It is intended to be a complete editable handoff, not only a list of
time ranges. A recipient can import the package without having the sender's
Photos library or sandbox paths.

Legacy schema v1 and v2 files were flat JSON reference files. They remain
readable, but their source footage can only be recovered from a matching Photos
asset or by relinking it.

## Package layout

```text
Project.reelclip/
|-- manifest.json
`-- Media/
    |-- Sources/
    |   `-- <attachment-id>-<original-name>.<ext>
    `-- Rendered/
        `-- <attachment-id>-<clip-name>.<ext>
```

`manifest.json` contains `ReelClipProjectEnvelope`:

- stable format identifier, schema version, writer app version, and export date
- the project payload, including every scene and planned range
- an attachment table with relative paths and exact byte counts
- explicit project-source, scene-source, and rendered-clip links

The package does not contain absolute paths. On import, every attachment is
validated, copied into the recipient's private workspace, and remapped before
the project is persisted. Sender-specific Photos local identifiers are also
removed because embedded media makes them unnecessary.

## State that must round-trip

- project ID, name, creation/update dates, active scene, and scrub position
- each scene's source metadata, active cut mode, prompt, and planned ranges
- range reason, lock state, source times, order, and originating cut mode
- highlight draft and timeline zoom
- Fixed recipe text/buttons state, count, duration, spacing, random bounds,
  random toggles, and random seed
- per-scene transcript and transcript timing
- saved ranges and available rendered clips
- user-curated project export order and saved-clips order
- export resolution and frame-rate settings

## Deliberately excluded data

Proxies, thumbnail filmstrips, waveform caches, loading progress, open sheets,
and in-flight drag state are derived or transient. The receiving app rebuilds
them from the embedded originals. Exports always continue to use original
source media, never a proxy.

## Validation and compatibility

- schema versions newer than the app supports are rejected with an update
  message; v1 through v3 are accepted
- package manifests are capped at 20 MB and 1,000 attachments
- attachment paths must be relative, remain inside the package, and contain no
  symbolic links or parent-directory components
- transferred byte counts must match the manifest before import
- duplicate IDs and missing source/render links are rejected
- source files are deduplicated when multiple scenes use the same footage
- export staging uses hard links where possible to avoid duplicating multi-GB
  originals inside the app container
- iCloud-backed package imports allow up to ten minutes to materialize before
  reporting a timeout

## Versioning policy

Additive optional payload fields do not require old readers to infer values;
they decode to safe defaults. Any incompatible shape or changed semantic
meaning requires a schema bump and a migration test. The test suite must retain
at least one legacy flat-file fixture and one complete package round trip.
