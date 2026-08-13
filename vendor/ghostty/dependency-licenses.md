# Ghostty embedded dependency license audit

This inventory is for TodoAgent's pinned macOS `ReleaseFast` archive built by
`scripts/setup-ghostty.sh`. It was derived from the exact Zig content hashes in
Ghostty's `build.zig.zon` files, the fetched package license files, and the
members of `libghostty-internal-fat.a`. Paths under the Zig cache are written
as `$ZIG_CACHE/p/<content-hash>/...`; the cache itself is not shipped.

The release gate is: no dependency may remain `unknown`, and every notice
required by a linked or copied work must be represented in the app-bundled
`THIRD_PARTY_NOTICES.md` or `ThirdPartyLicenses/`. This is an engineering
audit, not legal advice.

## Compiled or statically linked

| Component | Exact source identity | License choice used | Evidence |
| --- | --- | --- | --- |
| Ghostty | commit `4dcb09ada0c0909717d92547623b26eafa50ca8a` | MIT | source `LICENSE` |
| FreeType | Ghostty hash `N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub` | FreeType License (FTL) | `$ZIG_CACHE/p/<hash>/LICENSE.TXT`; archive `ft*.o` |
| libpng | hash `N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD` | libpng-2.0 | `$ZIG_CACHE/p/<hash>/LICENSE`; archive `png*.o` |
| zlib | hash `N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o` | Zlib | `$ZIG_CACHE/p/<hash>/LICENSE`; archive compression objects |
| Oniguruma | hash `N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c` | BSD-2-Clause | `$ZIG_CACHE/p/<hash>/COPYING`; archive `reg*.o`, encodings |
| glslang | hash `N-V-__8AABzkUgISeKGgXAzgtutgJsZc0-kkeqBBscJgMkvy` | BSD-3-Clause plus upstream third-party notices | `$ZIG_CACHE/p/<hash>/LICENSE.txt`; archive shader objects |
| SPIRV-Cross | hash `N-V-__8AANb6pwD7O1WG6L5nvD_rNMvnSc9Cpg1ijSlTYywv` | Apache-2.0 and Khronos Free Use | `$ZIG_CACHE/p/<hash>/LICENSE`, `LICENSES/LicenseRef-KhronosFreeUse.txt`; archive `spirv_*.o` |
| simdutf 9.0.0 | Ghostty vendored files SHA-256 `d3501fc2...` (header), `38dc5481...` (source) | Apache-2.0 OR MIT; TodoAgent uses Apache-2.0 | `pkg/simdutf/vendor/simdutf.h` declares `SIMDUTF_VERSION` 9.0.0; the wrapper zon's stale 5.2.8 metadata is not used as version evidence; archive `simdutf.o` |
| Highway | commit `66486a10623fa0d72fe91260f96c892e41aceb06` | Apache-2.0 and BSD-3-Clause | `$ZIG_CACHE/p/N-V-__8AAGm.../LICENSE`, `LICENSE-BSD3`; archive highway objects |
| Dear ImGui 1.92.5 docking | hash `N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI` | MIT | `$ZIG_CACHE/p/<hash>/LICENSE.txt`; archive `imgui*.o` |
| Dear Bindings 0.17 generated C API | hash `N-V-__8AANT61wB--nJ95Gj_ctmzAtcjloZ__hRqNw5lC1Kr` | MIT | exact generated archive; upstream `dearimgui/dear_bindings` MIT; archive `dcimgui*.o` |
| Wuffs | hash `N-V-__8AAAzZywE3s51XfsLbP9eyEw57ae9swYB9aGB6fCMs` | Apache-2.0 OR MIT; TodoAgent uses Apache-2.0 | `$ZIG_CACHE/p/<hash>/LICENSE-APACHE`; archive `wuffs-v0.4.o` |
| pixels | hash `N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc` | CC0-1.0 | `$ZIG_CACHE/p/<hash>/LICENSE`; Wuffs image path |
| libxev | commit `34fa50878aec6e5fa8f532867001ab3c36fae23e` | MIT | `$ZIG_CACHE/p/libxev-.../LICENSE`; imported into Ghostty Zig module |
| z2d 0.10.0 | hash `z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ` | MPL-2.0 | SPDX headers on every shipped source; imported into Ghostty Zig module |
| uucode 0.2.0 | hash `uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9` | MIT | `$ZIG_CACHE/p/<hash>/LICENSE.md`; generated Unicode tables and module |
| zf 0.10.3 | commit `3c52637b7e937c5ae61fd679717da3e276765b23` | MIT | `$ZIG_CACHE/p/zf-.../LICENSE`; imported without TUI |
| zig_objc | commit `f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae` | MIT | `$ZIG_CACHE/p/zig_objc-.../LICENSE`; macOS module |
| Ghostty macOS support library | same pinned Ghostty tree | MIT | `pkg/macos`, Ghostty root `LICENSE`; archive `zig_macos.o` |
| STB image and image resize | files in pinned Ghostty tree | MIT (selected from MIT/Public Domain alternatives) | `src/stb/stb_image.h`, `stb_image_resize.h`; archive `stb.o` |
| Zig compiler runtime | Zig 0.15.2 | MIT | toolchain `LICENSE`; archive `compiler_rt.o` |
| Chromium DOM code table | upstream Chromium table, transformed in pinned Ghostty | BSD-3-Clause | `src/input/keycodes.zig` attribution; Chromium `LICENSE` |
| foot function-key table | upstream foot table, transformed in pinned Ghostty | MIT | `src/input/function_keys.zig` attribution; foot `LICENSE` |
| Hoehrmann UTF-8 decoder | upstream DFA, modified in pinned Ghostty | MIT | `src/terminal/UTF8Decoder.zig` attribution; upstream license |
| X.Org rgb data | upstream X.Org rgb table | MIT/X11 | `src/terminal/x11_color.zig`, embedded `rgb.txt`; X.Org `COPYING` |

`z2d` is MPL-2.0 file-level copyleft. It is compiled from unmodified upstream
sources; MPL does not impose executable-wide relicensing. The exact
corresponding source archive is fixed by Ghostty's Zig hash and remains
obtainable at
`https://deps.files.ghostty.org/z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz`.

The app bundles verbatim license evidence for every row above under
`TerminalResources/ThirdPartyLicenses/`. The filenames and SHA-256 values in
that directory's `MANIFEST.md` are the release audit boundary.

## Copied runtime resources

| Resource | License | Distribution treatment |
| --- | --- | --- |
| Ghostty terminfo | MIT | Compiled from the pinned Ghostty source. |
| Fish, Nushell, and Elvish shell integration | MIT (Ghostty) | Source scripts are shipped verbatim. |
| Bash and Zsh Ghostty integration | GPL-3.0-or-later (Kitty-derived) | Source scripts are shipped verbatim and the complete GPLv3 text is bundled. |
| `bash-preexec.sh` | MIT, Ryan Caloras and contributors | Source is shipped verbatim and its notice is bundled. |
| iTerm2 theme collection | not distributed | Build fixes `-Demit-themes=false`; the required directory is intentionally empty. |

## Deliberately excluded

- GNU libintl/gettext: `-Di18n=false` plus the source-shape-validated scratch
  dependency gate; no `intl` member or gettext symbol remains in the archive.
- Sentry Native and Breakpad: `-Dsentry=false`; no Sentry/Breakpad member or
  symbol remains in the archive.
- The theme archive, fonts, GTK/Wayland dependencies, libxml2, HarfBuzz, and
  other platform/application-only inputs are not linked or copied by this
  native macOS library build.

## Release verification

Run `./scripts/setup-ghostty.sh --check`, then inspect the final app's bundled
`THIRD_PARTY_NOTICES.md`, `ThirdPartyLicenses/`, and `GPL-3.0.txt`. The final Mach-O must also pass an undefined-symbol
scan; ImGui definitions exist within the Ghostty archive and no final executable
may retain an unresolved `_ImGui*`, `_ImFont*`, gettext, or Sentry symbol.
