# Local shader patches

A patch here exists for one reason: Leaf needs a fix that upstream has not
shipped yet. It is a temporary carry, not a fork. Every patch is pinned by the
sha256 of the target file **before** and **after** the change, so the build can
never silently do the wrong thing:

- if the source lock advances and the target file changes, the `pre_sha256`
  check fails the build and asks you to re-check whether the patch is still
  needed;
- if the diff applies but produces anything other than the pinned result, the
  `post_sha256` check fails the build.

The fetched checkout is never edited in place. Patched copies are materialized
into the build's temporary directory, so a build without the patch is
unaffected, and `workdir/` stays a faithful mirror of the pin.

## Declaring one

Add an entry to the `patches` array in `mlp1-glsl-selection.json`:

```json
{
  "id": "zfast-crt-geo-precision",
  "source_id": "libretro-glsl-shaders",
  "path": "crt/shaders/zfast_crt_geo.glsl",
  "patch_file": "shader-sources/patches/zfast_crt_geo-precision.patch",
  "pre_sha256": "<sha256 of the file at the pinned commit>",
  "post_sha256": "<sha256 of the patched result>",
  "reason": "why this is needed, concretely",
  "upstream_status": "where the upstream fix stands, and when to drop this"
}
```

`reason` and `upstream_status` are not decoration. They are what tells the next
person whether the patch can go away. Write `upstream_status` so that a future
reader can answer "is this still needed?" without re-deriving the whole
investigation.

Every patched file is declared in the built `manifest.json` under `patches`, and
its per-file row carries `patch_id`, `patch_sha256`, and the original
`source_sha256`. A reader never has to diff the bundle against the pin to
discover that a file was modified.

## Removing one

When upstream carries the change, advance the source lock and delete the patch
entry and its file. The `pre_sha256` check will already have failed the build at
that point, which is the intended prompt.

## Current patches

| Patch | Target | Status |
| --- | --- | --- |
| `zfast-crt-geo-precision` | `crt/shaders/zfast_crt_geo.glsl` | Not yet submitted upstream. Upstream `c6c8fad` (#563) introduced a vertex/fragment `COMPAT_PRECISION` mismatch in six shaders; `8aab130` fixed two of them and left this one. The patch applies that same change here. Drop it once upstream carries it. |

---

# License acknowledgements

Separate mechanism, same repository, so it is documented here too.

The generator walks the **whole dependency closure** of every preset and checks
each file entering the bundle against that preset's declared license. This is
deliberately wider than the per-preset `license_evidence_path` check, which
validates exactly one nominated file and therefore cannot see a stricter
dependency hiding behind a compliant one.

Two failure modes are rejected:

- **A stricter file under a laxer preset.** A GPL-3.0 dependency under a
  `GPL-2.0-or-later` preset silently relicenses the bundle. `libretro/glsl-shaders`
  really is mixed — most files are v2-or-later, but `crt-potato`, `gtu-v050`,
  `tvout-tweaks`, and `cut` are v3 — so this is a live hazard, not a theoretical
  one. (FreeBSD's port of the same repo records GPLv3 for exactly this reason:
  it ships the whole tree. Leaf ships a curated subset that contains none.)
- **A source file with no notice at all**, unless it is acknowledged.

## Acknowledging an unlabelled file

Only `.glsl` sources need a notice; `.glslp` presets and `.png` assets follow
their preset. When a source genuinely has none, add to
`mlp1-glsl-selection.json`:

```json
"license_acknowledgements": [
  {
    "path_prefix": "crt/shaders/crt-consumer/",
    "license": "GPL-2.0-or-later",
    "reason": "why this file may be redistributed under that license",
    "decision": "0010"
  }
]
```

An acknowledgement covers a **missing** notice. It can never override a stated
one: a file declaring GPLv3 is still rejected under a `GPL-2.0-or-later` preset
even inside an acknowledged prefix. Write `reason` for someone who has to defend
the choice later, and point at a decision record when there is one.

The result is written into the built `manifest.json` as `license_audit`, one row
per file, each saying whether its license was declared in the file, inherited
from the preset, or acknowledged — and on what grounds.

---

# Released aliases

A third mechanism in the same selection file, for the same reason: something a
future edit could break silently.

A user's saved automatic preset references a recommendation **by path**. Once
`leaf-recommended/crt-curved.glslp` has shipped, that path, the preset it
references, and its parameter values are API. Retuning it in place changes a
look the user chose and saved, with no signal to them and no record for us.

`released_aliases` in `mlp1-glsl-selection.json` pins each shipped alias:

```json
{
  "path": "leaf-recommended/crt-curved.glslp",
  "reference": "leaf-bundled/crt/zfast_crt_geo.glslp",
  "parameters": {},
  "released_in": "2026-09-01"
}
```

The build fails if a released alias changes its reference target, changes any
parameter value, or disappears. A material retune is therefore a **new alias
path**, with the old one kept loadable for at least one stable release — which
is what decision 0008 in the plan requires.

`released_in` is a marker for when the alias may eventually be retired, not a
version to bump. Do not edit an existing entry to make a build pass; that
defeats the entire mechanism. Add a new alias instead.
