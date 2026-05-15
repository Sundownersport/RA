# retroarch-builds

UMRK's RetroArch source/build repo.

This fork starts from `spruceUI/RA`, keeps the existing device-oriented Docker
and Actions build scripts intact, and adds a **Mac-first local build lane** for
day-to-day bring-up and troubleshooting.

## Current milestone

Produce a reproducible local macOS RetroArch build from a pinned upstream
`libretro/RetroArch` checkout.

The current Mac lane intentionally builds against a clean upstream checkout at
`v1.22.2` and uses RetroArch's non-Metal macOS Xcode project. On this host that
is the cleanest working path:

- the Metal Xcode project currently requires the separately installed Metal
  Toolchain component
- the Unix `./configure && make` path hits multiple Apple-toolchain regressions
- the non-Metal Xcode project succeeds with a modern deployment-target override

## Quick start

```sh
cd /Volumes/Storage/UMRK/retroarch-builds
./bootstrap-mac.sh
./build-mac.sh
```

Outputs:

- binary: `output/macos/RetroArch`
- app bundle: `output/macos/RetroArch.app`

## How it works

1. `fetch-retroarch.sh` clones or updates an external working checkout in
   `workdir/src/RetroArch`
2. `build-mac.sh` runs `xcodebuild` against
   `pkg/apple/RetroArch.xcodeproj`
3. the script copies the finished app bundle and executable into `output/macos`

The upstream RetroArch source is **not** committed into this repo.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `RETROARCH_VERSION` | `v1.22.2` | Upstream RetroArch tag to check out |
| `RETROARCH_UPSTREAM_URL` | `https://github.com/libretro/RetroArch.git` | Upstream source remote |
| `RETROARCH_WORKDIR` | `./workdir` | Local ignored workspace for source + DerivedData |
| `RETROARCH_SRC_DIR` | `./workdir/src/RetroArch` | External RetroArch checkout path |
| `RETROARCH_DERIVED_DATA` | `./workdir/DerivedData` | Xcode build products/intermediates |
| `OUTPUT_DIR` | `./output/macos` | Final copied app + binary |
| `RETROARCH_XCODE_PROJECT` | `pkg/apple/RetroArch.xcodeproj` | macOS Xcode project path inside source checkout |
| `RETROARCH_XCODE_SCHEME` | `RetroArch` | Xcode scheme to build |
| `RETROARCH_BUILD_CONFIGURATION` | `Release` | Xcode configuration |
| `MACOSX_DEPLOYMENT_TARGET` | `11.0` | Modern floor required by the current Xcode toolchain |
| `ARCHS` | host arch from `uname -m` | Target architecture passed to `xcodebuild` |

## Notes

- `bootstrap-mac.sh` validates the local macOS toolchain. Homebrew is checked
  because it remains the preferred way to manage future auxiliary dependencies,
  but the current non-Metal Xcode path does not require any specific formulae.
- The existing `build.sh`, `build-a30.sh`, `build-universal32.sh`, and related
  Docker/device scripts from `spruceUI/RA` are still here for later CI/device
  work.
- A future Mac lane can revisit `pkg/apple/RetroArch_Metal.xcodeproj` once the
  host has the Metal Toolchain component installed.
