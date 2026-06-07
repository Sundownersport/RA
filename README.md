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
./bootstrap-mac.sh
./build-mac.sh
```

MLP1 vertical-slice build:

```sh
./build-mlp1.sh
./smoke-mlp1-command.sh
```

MLP1 build with Jawaka's current patch set:

```sh
MLP1_PATCH_SET=portrait-rotation,command-menu,jawaka-load-content ./build-mlp1.sh
./smoke-mlp1-command.sh
```

Jawaka app tile packaging:

```sh
make package-native
make package-platform PLATFORM=mlp1
make install-jawaka-app
make adb-stage-pak-mlp1
```

Preferred device staging is from `../Leaf`:

```sh
make -C ../Leaf stage-retroarch DEVICE=mlp1      # binary + cores + info
make -C ../Leaf stage-app APP=retroarch-builds DEVICE=mlp1
```

Outputs:

- binary: `output/macos/RetroArch`
- app bundle: `output/macos/RetroArch.app`
- MLP1 binary: `output/mlp1/bin/retroarch`
- MLP1 build manifest: `output/mlp1/build-manifest.json`
- Jawaka pak: `build/package/RetroArch.pak` (staged under `Apps/shared/`)

## How it works

1. `fetch-retroarch.sh` clones or updates an external working checkout in
   `workdir/src/RetroArch`
2. `build-mac.sh` runs `xcodebuild` against
   `pkg/apple/RetroArch.xcodeproj`
3. the script copies the finished app bundle and executable into `output/macos`
4. `build-mlp1.sh` runs inside the local MLP1 toolchain image and writes an
   MLP1 manifest next to the staged binary
5. the Makefile packages `RetroArch.pak`, a small shared Jawaka app wrapper
   that calls `jawaka-retroarch-runner --menu` so shared config policy stays in
   Jawaka

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

### MLP1 environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `TOOLCHAIN_IMAGE` | `ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local` | Local Docker image used for MLP1 builds |
| `TOOLCHAIN_REPO` | adjacent `../mlp1-toolchain` checkout | Toolchain repo mounted for binary verification |
| `OUTPUT_DIR` | `./output/mlp1` | Final staged MLP1 output |
| `BUILD_MANIFEST` | `./output/mlp1/build-manifest.json` | Generated manifest for the MLP1 binary |
| `MLP1_NATIVE_WAYLAND` | `0` | Native Wayland path; default uses SDL2 video |
| `MLP1_ENABLE_UDEV` | `auto` | Enables udev only when SDK development files are present |
| `MLP1_ENABLE_MALI_FBDEV` | `0` | Optional Mali fbdev build flag |
| `MLP1_APPLY_COMMON_PATCHES` | `0` | Disabled guard against applying Spruce/common patches implicitly |
| `MLP1_PATCH_SET` | empty | Comma-separated explicit patch set |
| `JOBS` | container CPU count | Parallel make jobs |

Supported `MLP1_PATCH_SET` entries:

| Entry | Purpose |
| --- | --- |
| `portrait-rotation` | rotate RetroArch's logical landscape output for the MLP1 portrait panel |
| `command-menu` | add focused UDP command-menu commands for Jawaka |
| `jawaka-load-content` | add Jawaka's load-content command path for resident/same-core switching |

## Notes

- `bootstrap-mac.sh` validates the local macOS toolchain. Homebrew is checked
  because it remains the preferred way to manage future auxiliary dependencies,
  but the current non-Metal Xcode path does not require any specific formulae.
- The existing `build.sh`, `build-a30.sh`, `build-universal32.sh`, and related
  Docker/device scripts from `spruceUI/RA` are still here for later CI/device
  work.
- A future Mac lane can revisit `pkg/apple/RetroArch_Metal.xcodeproj` once the
  host has the Metal Toolchain component installed.
- The MLP1 lane intentionally starts from a clean upstream RetroArch checkout
  with `--enable-networking` and `--enable-command`. Spruce/common patches are
  not applied implicitly; use `MLP1_PATCH_SET` with explicit patch names.
- Leaf's default MLP1 runtime build uses
  `portrait-rotation,command-menu,jawaka-load-content`.
- The build script reverses applied patches before exiting so
  `workdir/src/RetroArch` stays reusable for later clean or patched builds.
