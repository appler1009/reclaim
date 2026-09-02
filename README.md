# Reclaim

A native macOS disk-space analyser in the spirit of GrandPerspective, pointed at one job:

**find the space worth reclaiming, and move it to the Trash on your confirmation.**

Every file becomes a tile sized by the space it occupies. On top of that map, Reclaim
calls out the things that are actually safe to delete — build output, package caches,
app caches, the Trash, stale downloads — and lets you tick them off and bin them.

![the empty state, before a scan](docs/screenshot.png)

## Why not just a treemap

A treemap tells you *where* the bytes are. It does not tell you which of them you can
afford to lose. Reclaim adds that second half:

| | |
|---|---|
| **Spotlight waste** | Everything non-reclaimable dims; reclaimable tiles burn in their category colour |
| **SAFE vs REVIEW** | Rebuildable things (`node_modules`, caches, Trash, logs) are separated from things that need a human look (installers, stale downloads, big-and-old files) |
| **Select safe categories** | One click stages every SAFE category |
| **Trash, never `rm`** | Deletion is `FileManager.trashItem`. Nothing is removed permanently, and you see the full path list before anything moves |

## What it flags

| Category | Safety | Examples |
|---|---|---|
| Build artifacts | SAFE | `node_modules`, `DerivedData`, `Pods`, `.next`, `.turbo`, `__pycache__`, `target`/`build` next to a real project marker |
| Developer caches | SAFE | `.npm`, `.cargo`, `.gradle`, `.m2`, `iOS DeviceSupport`, `CoreSimulator` |
| App caches | SAFE | `~/Library/Caches`, per-container `Caches`, `.cache` |
| Trash | SAFE | `~/.Trash` contents |
| Logs & crash reports | SAFE | `Library/Logs`, `DiagnosticReports`, `*.log` over 10 MB |
| Installers & archives | REVIEW | `.dmg`/`.pkg`/`.iso`/`.zip` over 100 MB and older than 30 days |
| Stale downloads | REVIEW | `~/Downloads` items over 20 MB untouched for 90 days |
| Big & untouched | REVIEW | Anything over 512 MB untouched for a year |

A matched directory is reported whole and never descended into, so you get
`node_modules` as one 12 GB decision instead of forty thousand files.

## Build and run

```sh
./Scripts/build_app.sh          # → dist/Reclaim.app
open dist/Reclaim.app
```

The script builds a release binary, generates the app icon, writes `Info.plist`, and
signs the bundle. If a `Developer ID Application` certificate for the team is in your
keychain it signs with that plus hardened runtime and a secure timestamp; otherwise it
falls back to an ad-hoc signature.

```sh
TEAM_ID=XXXXXXXXXX BUNDLE_ID=com.example.reclaim ./Scripts/build_app.sh
```

To hand the app to someone else, notarize it (one-time credential setup is documented
at the top of the script):

```sh
xcrun notarytool store-credentials reclaim-notary \
  --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
./Scripts/notarize.sh
```

### Permissions

Reclaim is deliberately **not sandboxed** — the whole point is to measure whatever
folder or volume you point it at. macOS will still prompt once for Desktop, Documents
and Downloads access. To scan the whole disk, grant the app **Full Disk Access** in
System Settings → Privacy & Security. Directories it cannot read are counted as
unreadable rather than silently skipped.

### Headless mode

The same scanner and analyser run in the terminal, which is how the numbers below were
verified:

```sh
.build/release/DiskMap --scan ~/Library
```

## How it works

| File | Role |
|---|---|
| `Scanner.swift` | Parallel directory walk. A LIFO job queue feeds `4 × cores` workers; each directory is read by exactly one worker so no locks are needed on the tree, and sizes are summed afterwards in one iterative post-order pass. Stays on a single volume, counts hard links once, records both logical (`st_size`) and on-disk (`st_blocks × 512`) size. |
| `Treemap.swift` | Squarified treemap layout (Bruls, Huizing & van Wijk), computed off the main thread. Directories too small to expand collapse into a single tile. |
| `TreemapView.swift` | AppKit rendering. The map is drawn once into a cached image; only hover and selection chrome are redrawn as the pointer moves. |
| `WasteAnalyzer.swift` | Single pass over the tree applying the rules above, grouped into categories. |
| `AppModel.swift` | Scan lifecycle, staging set, and the Trash operation. |
| `ContentView.swift` | SwiftUI chrome: header metrics, breadcrumb, hover readout, reclaim sidebar, confirmation dialogs. |

Scanning is bound by I/O latency, not CPU, which is why the worker pool oversubscribes
the cores by 4×. On a 274k-file `~/Library`, that took the scan from **73 s to 2.2 s**.
Totals are byte-exact against `du -sk`.

## Requirements

macOS 14+, Swift 6 toolchain (Xcode 16+).
