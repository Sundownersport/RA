# retroarch-builds

This repo will own RetroArch compilation, patching, packaging, and release automation for UMRK.

## Purpose

Provide a dedicated place for:

- RetroArch source integration
- patches
- build scripts
- packaging metadata
- release automation

## First milestone

Make it build locally on **Mac**.

The repo should be structured so that local development and troubleshooting come first, while leaving room for CI-based builds later.

## Longer-term direction

Adopt a GitHub Actions/release-artifact workflow similar in spirit to spruceUI's RetroArch build pipeline.

## Boundaries

This repo should contain:

- source references
- build logic
- patch sets
- configuration
- packaging scripts

This repo should **not** rely on committing compiled binaries into git as the normal workflow. Finished outputs should eventually be published as build artifacts or release assets.
