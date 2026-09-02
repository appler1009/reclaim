# Reclaim

A native macOS app that shows **where your disk space actually went** — and lets you
move things to the Trash yourself, on your own judgement.

![Reclaim showing a scanned folder](docs/screenshot.png)

It does not tell you what you should delete. It measures, shows, and gets out of the way.

## How it works, from the outside

Pick a **volume** or a folder. Reclaim scans it and shows the folder you are looking at
as a single level of tiles, each sized by the space it takes:

- **One level at a time.** Every immediate child is one labelled tile — name, size,
  share of the folder, file count — instead of a mosaic of sub-pixel specks. Double-click
  a tile (or click a row in the list) to go inside it; **Up**, the breadcrumb, or **⌘↑**
  to come back out.
- **Colour says what kind of thing it is.** Each tile is coloured by the kind of file it
  mostly contains — code, media, images, archives, documents, apps, data.
- **One set of numbers.** The strip at the top always describes the folder currently in
  view: its size, its share of the scan, files inside, items here, free space on the volume.
- **The list is the same data, ranked.** Contents largest-first with share bars, then a
  by-file-type summary of everything below the current folder.
- **Deleting is yours to start.** Tick anything in the list (or any tile), review the exact
  paths in the confirmation, and it goes to the **Trash** — `FileManager.trashItem`, never
  an outright delete. You can put it all back.

## Build and run

```sh
./Scripts/build_app.sh          # → dist/Reclaim.app
open dist/Reclaim.app
```

The script builds a release binary, generates the icon, writes `Info.plist`, and signs the
bundle: with a `Developer ID Application` certificate plus hardened runtime and a secure
timestamp when one is in the keychain, ad-hoc otherwise.

```sh
TEAM_ID=XXXXXXXXXX BUNDLE_ID=com.example.reclaim ./Scripts/build_app.sh
./Scripts/notarize.sh           # after: xcrun notarytool store-credentials reclaim-notary …
```

### Permissions

Reclaim is deliberately **not sandboxed** — the point is to measure whatever you point it
at. macOS still prompts once for Desktop, Documents and Downloads. For a whole-disk scan,
grant **Full Disk Access** in System Settings → Privacy & Security. Anything unreadable is
counted and reported in the top strip rather than silently skipped.

### Terminal

The same engine runs headless, which is how the numbers below were measured:

```sh
Reclaim --volumes           # mounted volumes, used/free
Reclaim --scan <path>       # totals, contents largest-first, by-type summary
Reclaim --bench <path>      # layout time vs detail level
Reclaim --bench-draw <path> # render time vs detail level
Reclaim --open <path>       # launch the UI straight into a scan
```

## How it works, from the inside

| File | Role |
|---|---|
| `Scanner.swift` | Parallel directory walk: a LIFO queue feeds `4 × cores` workers, each directory read by exactly one worker so the tree needs no locks, then one iterative post-order pass sums sizes, counts files, and sorts every child list largest-first. Stays on one volume, counts hard links once, records logical and on-disk size. |
| `Treemap.swift` | Squarified layout (Bruls, Huizing & van Wijk), built by a class rather than a struct, over pre-sorted children. |
| `TreemapRenderer.swift` | Tile drawing with pre-resolved colours; shared by the view and the benchmarks. |
| `TreemapView.swift` | Live drawing, hit-testing, dirty-rect hover. No bitmap cache: the map is re-laid-out and redrawn at whatever size it is displayed at. |
| `Breakdown.swift` | Contents rows and per-type totals for the folder in view. |
| `Volumes.swift` | Mounted volumes with capacity and free space, refreshed on mount/unmount. |
| `AppModel.swift` | Scan lifecycle, navigation, selection, and the Trash operation. |
| `Log.swift` | Ships structured logs to a local [LogDock](../logdock) collector when one is running. |

### Performance

Measured on `~/Library` (≈270k files):

| | before | after |
|---|---|---|
| Scan | 73 s (serial) | **2.2 s** (parallel workers) |
| Treemap layout | 436 ms | **3.2 ms** |
| Full map render | — | **17.8 ms** |

The layout win came from profiling rather than guessing: a sampling profile showed nearly
all the time in `swift_retain`/`swift_release` and `initializeWithCopy for TreemapCell` —
the layout struct was being copied on every recursive call, and every directory was being
re-sorted on every pass. Building into a class, sorting children once at scan time, and
holding cells `unowned(unsafe)` removed it. Not expanding folders whose children would each
land on a fraction of a pixel cut the cell count from 143k to 36k, which is what made
rendering fast enough to redraw continuously while a window is dragged.

Scan totals are byte-exact against `du -sk`.

## Requirements

macOS 14+, Swift 6 toolchain (Xcode 16+). `LogShip` is a local path dependency on
`../logdock`; logging is inert if the collector is not running.
