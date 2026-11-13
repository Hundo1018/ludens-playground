# Asset policy

Art, animation, sound and fonts are not made in this repository. Every asset is openly licensed (CC0 or CC-BY 4.0), listed
with its URL, licence and author, and downloaded by script at build time with a checked sha256.

## Sources (checked from the build environment, 2026-11-13)

| Kind | Source | Licence | Scriptable download |
|---|---|---|---|
| Textures | Poly Haven, `dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_diff_1k.jpg` | CC0 | yes |
| Models (props, buildings) | Poly Haven API, `api.polyhaven.com/files/<id>` (glTF with textures) | CC0 | yes |
| Characters with skeleton and animation | Khronos glTF-Sample-Assets, `Models/CesiumMan`, `Models/Fox` (raw.githubusercontent.com) | CC-BY 4.0 | yes |
| Characters, many | Quaternius packs (Ultimate Animated Character Pack, Universal Animation Library) | CC0 | no: web buttons only; optional manual download |
| Motion capture | CMU Graphics Lab, `mocap.cs.cmu.edu/subjects/NN/NN_MM.amc` and `NN.asf` | free to copy, modify and redistribute (site statement) | yes |
| Sound | OpenGameArt, "512 sound effects (8-bit style)" | CC0 | yes (zip) |
| Fonts | Google Fonts repo, `ofl/pressstart2p`, `ofl/silkscreen` (OFL.txt included) | SIL OFL 1.1 | yes |

Not used: Kenney (403 from the build environment); Mixamo (Adobe terms do not allow redistribution).

## Rules

- Only the sources above, or others that are CC0 or CC-BY 4.0 and recorded with a URL and a licence, may be added.
- Each asset gets a line in `assets/manifest.toml` with `url`, `sha256`, `license`, `author`, `source_page`.
- `assets/CREDITS.md` is generated from the manifest, never edited by hand. A CC-BY asset without an author fails the build.
- Hand-written code covers: shaders and lighting, scene layout, collision shapes that the player does not see, debug drawing,
  HUD layout, and the simulation's own shapes (cloth, rope, soft body). Anything a player sees as art comes from the manifest.
