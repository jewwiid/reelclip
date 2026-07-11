# Swift & iOS Development Resources

Curated, legitimately-free Swift and iOS development references bundled with this
repo. All material here is either:

- **Apple-published** under an open license (Apache 2.0 / CC BY 4.0), or
- **Apple-official** (the Swift book source, Swift Evolution proposals), or
- A **curated link** to a free web resource (no download involved).

Commercial iOS books (Hacking with Swift PDFs, Ray Wenderlich, anything pirated)
are NOT included — those are copyrighted even when free to read online. Use the
links in [resources/README.md](resources/README.md) for those, accessed legally
on the publisher's site.

## Folder layout

| Path | What it is | License | Size |
|--|--|--|--|
| [`the-swift-programming-language/`](the-swift-programming-language/) | Apple's official *The Swift Programming Language* book (TSPL), full source as a DocC catalog (Swift 6.4 beta) + a pre-built EPUB for offline reading in Books/iBooks. | Apache 2.0 + CC BY 4.0 (docs) | ~12 MB |
| [`swift-evolution/`](swift-evolution/) | All 539 Swift Evolution proposals (`SE-0001` through current). The design rationale for every language feature, accepted or rejected. The gold mine for understanding *why* Swift is the way it is. | Apache 2.0 | ~11 MB |
| [`swift-org-docs/`](swift-org-docs/) | Placeholder for hand-curated notes from swift.org. The docs are best read online (https://docs.swift.org) — offline mirrors go stale fast. | — | — |
| [`resources/`](resources/) | Curated links to legitimately-free web resources: Apple developer docs, Swift forums, Hacking with Swift free articles, objc.io, Point-Free, SwiftLee, etc. **No downloads — these stay as live URLs** so they stay current. | — | — |

## How to use the bundled content

### The Swift Programming Language (TSPL)

The folder has the source as a `.docc` (Documentation Catalog) **plus** a
pre-built EPUB for offline reading. Three ways to use it:

1. **EPUB on iPhone/iPad/Mac** — `swift-book.epub` is the full book rendered
   to EPUB. Double-click to open in Books/Books.app, or transfer via
   AirDrop. Works offline, syncs your reading position across Apple devices
   if you're signed into iCloud. **This is the path of least resistance.**
   - Provenance: built from the same open-source DocC source as the `.docc`
     folder, via the community
     [swift-book-pdf](https://github.com/Swift-Book-CN/swift-book-pdf) tool.
     Content matches Apple's official text; only the format is community-rendered.
   - MD5: `f92f3078da8acd8514ec8018d70c9fa7` (for verifying integrity after
     a `git pull` or re-download).

2. **In Xcode** — open the `TSPL.docc` folder in Xcode 16+. The book renders
   inline with sidebar navigation, full-text search, and code samples you can
   copy. Cmd-click any symbol to jump to its definition. This is the same
   format Apple uses for its online documentation.

3. **As raw markdown** — the chapters live under `TSPL.docc/LanguageGuide/` and
   `TSPL.docc/ReferenceManual/` as individual `.md` files. You can read them
   in any text editor or use `grep`/`ripgrep` to search across all of them
   at once. This is great for finding every mention of a specific concept
   (e.g. "where is `Sendable` actually defined?").

To convert the source to PDF or a different EPUB version yourself, use
[swift-book-pdf](https://github.com/Swift-Book-CN/swift-book-pdf) (a community
tool that renders the same source to print-ready formats).

### Swift Evolution proposals

The `swift-evolution/proposals/` folder has all 539 proposals (`0001-nnnn-*.md`).
Start with the most impactful ones for day-to-day Swift work:

- `SE-0029` — Remove implicit tuple splat behavior
- `SE-0066` — Standardize function type argument syntax
- `SE-0099` — Restrict `Self` use
- `SE-0110` — Distinguish between single-tuple and multiple-argument arguments
- `SE-0156` — Class and Subtype existentials
- `SE-0166` — Swift Archival & Serialization (notice the **rejection** rationale)
- `SE-0196` — Compiler diagnostic directives
- `SE-0206` — HMAC-based Swift API names
- `SE-0216` — Dynamic callable
- `SE-0227` — Identity and find references
- `SE-0235` — Add Result
- `SE-0245` — Add an integer init to `Collection` (count)
- `SE-0258` — Property wrappers
- `SE-0266` — Prioritized work items
- `SE-0281` — `@main`
- `SE-0286` — Forward scan matching
- `SE-0290` — Unavailable from async
- `SE-0302` — `if let` shorthand for optional binding
- `SE-0306` — Actors
- `SE-0311` — Task local values
- `SE-0313` — Improved control flow
- `SE-0325` — Async effects
- `SE-0326` — `async`/`await`
- `SE-0331` — Remove `sendable` for unsafe pointers
- `SE-0337` — Incremental migration to concurrency checking
- `SE-0345` — `if let` shorthand
- `SE-0352` — Implicitly opened existentials
- `SE-0376` — Function back deployment
- `SE-0382` — Expression macros
- `SE-0388` — `where` clauses on bound generic parameters
- `SE-0408` — `Pack` iteration
- `SE-0420` — `Integer` parameterized protocols

The ones that are **rejected** are just as valuable as accepted ones — they
show what the community considered and why it didn't ship. Examples:
`SE-0001`, `SE-0003`, `SE-0004` (all early Swift design discussions),
`SE-0043` (declare variables with `var x: Int = 0` — rejected),
`SE-0083` (bridge `NSError` to `Error` — superseded), `SE-0166` (Codable
predecessor), `SE-0215` (custom async/await syntax — rejected in favor of
SE-0316), `SE-0253` (synthesized `Comparable` for enums — partial).

To search across all proposals, use:
```bash
grep -rl "async" swift-evolution/proposals/ | head -20
```

## When to read what

| You want to… | Read |
|--|--|
| Learn Swift syntax from scratch | TSPL → *A Swift Tour* + *Language Guide* |
| Understand a specific feature | Find it in TSPL first, then read the corresponding SE proposal for the design rationale |
| Know why a feature was *rejected* | Read the proposal — rejected ones explain the tradeoffs that were considered |
| Find a built-in API | https://developer.apple.com/documentation/ (online; not bundled) |
| See a worked example | Apple sample code (links in `resources/`) |
| Read about advanced patterns (e.g. protocols, generics) | TSPL *Language Guide* → relevant chapter, then the SE proposals it references |
| Build for SwiftUI / UIKit / Combine / SwiftData | Apple developer documentation (online; not bundled — too large and changes too often) |

## What this folder deliberately does NOT include

- Pirated PDFs of commercial iOS books (Hacking with Swift, Ray Wenderlich, etc.). Use the free web versions.
- Apple API documentation (UIKit, SwiftUI, Foundation). The official site is the only canonical source and offline mirrors go stale within weeks. Use https://developer.apple.com/documentation/.
- WWDC session videos. The official site is the right place; downloads are large and the videos change with each year's session.
- Xcode itself or any Apple SDKs. Those are downloaded via Xcode or developer.apple.com/download.
- Swift toolchain binaries. Use https://swift.org/download/ or `xcode-select`.

## Updating the bundled content

The bundled content is version-pinned. To refresh:

```bash
cd docs/swift-ios-resources/the-swift-programming-language
rm -rf TSPL.docc LICENSE.txt README.md
git clone --depth 1 https://github.com/apple/swift-book.git
mv swift-book/TSPL.docc . && mv swift-book/LICENSE.txt . && mv swift-book/README.md .
rm -rf swift-book
# The EPUB is NOT auto-regenerated — re-run swift-book-pdf against the new
# .docc, or pull a fresh copy from the Swift Book Archive community
# releases: https://github.com/Swift-Book-CN/SwiftBookArchive/releases

cd ../swift-evolution
rm -rf LICENSE.txt README.md proposals process.md commonly_proposed.md policies proposal-templates
git clone --depth 1 https://github.com/apple/swift-evolution.git swift-evo-tmp
mv swift-evo-tmp/LICENSE.txt . && mv swift-evo-tmp/README.md . && mv swift-evo-tmp/proposals . && mv swift-evo-tmp/process.md . && mv swift-evo-tmp/commonly_proposed.md . && mv swift-evo-tmp/policies . && mv swift-evo-tmp/proposal-templates .
rm -rf swift-evo-tmp
```

(Last refreshed: 2026-07-08. ReelClip uses Swift 6.x.)
