# swift.org documentation

This folder is intentionally **empty**.

## Why no offline mirror

Swift.org's official documentation includes:
- https://docs.swift.org/swift-book/ (the Swift book — bundled in `../the-swift-programming-language/`)
- https://docs.swift.org/getting-started/
- https://www.swift.org/documentation/
- https://www.swift.org/install/

These change with every Swift release. Offline mirrors go stale within weeks,
and Apple's DocC renderer (used for the canonical versions) doesn't have a
good static-export story for sites this large.

## Use the live sites instead

For day-to-day work, just bookmark the live URLs:
- **Swift book**: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/
- **Standard library**: https://developer.apple.com/documentation/swift
- **API reference**: https://developer.apple.com/documentation/
- **Swift.org docs hub**: https://www.swift.org/documentation/
- **Swift package index**: https://swiftpackageindex.com/ (community-run, very useful)

## If you really need offline

Use Dash (https://kapeli.com/dash) — it has first-class Apple Docsets that
stay current automatically via background downloads. One-time purchase,
free trial. This is the standard tool for iOS devs who need offline docs.
