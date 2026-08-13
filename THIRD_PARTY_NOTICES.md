# Third-party notices

TodoAgent includes or derives software from the projects below. Generated
Ghostty build artifacts and runtime resources are produced by
`scripts/setup-ghostty.sh` from the exact revisions recorded in
`vendor/ghostty/pins.json`.

## agterm

- Source: <https://github.com/umputun/agterm>
- Revision: `9f1459254f37f384cb9d19921388b826eae1493d`
- Used for: the reference Swift/AppKit Ghostty embedding bridge

MIT License

Copyright (c) 2026 Umputun

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## GhosttyKit embedded dependencies

The exact component-by-component source hashes and license evidence are in
`vendor/ghostty/dependency-licenses.md`. The app bundles the corresponding
full license texts under `ThirdPartyLicenses/`. The binary includes FreeType (FTL),
libpng (libpng-2.0), zlib (Zlib), Oniguruma and glslang (BSD), SPIRV-Cross and
Khronos material (Apache-2.0/Khronos Free Use), simdutf, Highway and Wuffs
(Apache-2.0), Dear ImGui and Dear Bindings (MIT), pixels (CC0-1.0), libxev,
uucode, zf and zig_objc (MIT), z2d (MPL-2.0), Zig compiler runtime (MIT), and
the STB image loaders (MIT). It also contains attributed data/code derived
from Chromium, foot, Bjoern Hoehrmann's UTF-8 decoder, and X.Org rgb.

Release packaging must retain this notice, `ThirdPartyLicenses/`, the complete
`GPL-3.0.txt`, and the exact source-provenance file.

## bash-preexec

- Source: <https://github.com/rcaloras/bash-preexec>
- Used for: Ghostty Bash shell integration, shipped as source
- License: MIT

Copyright (c) 2017 Ryan Caloras and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Kitty-derived Ghostty shell integration

Ghostty's Bash integration and Zsh integration are based in part on Kitty and
are distributed under GPL-3.0-or-later. TodoAgent ships these scripts in source
form under `ghostty/shell-integration`; they remain separate interpreted works.

GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>
Everyone is permitted to copy and distribute verbatim copies of this license
document, but changing it is not allowed.

The complete, authoritative GPLv3 license text is bundled as `GPL-3.0.txt`.
The source-script headers identify their GPL-3.0-or-later grant and are
included verbatim in the application.

## macterm

- Source: <https://github.com/thdxg/macterm>
- Used for: portions of the Swift/AppKit Ghostty embedding bridge adapted by agterm

MIT License

Copyright (c) 2026 Macterm

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Ghostty

- Source: <https://github.com/ghostty-org/ghostty>
- Revision: `4dcb09ada0c0909717d92547623b26eafa50ca8a`
- Used for: `GhosttyKit.xcframework`, shell integration, and terminfo; terminal
  themes are deliberately not shipped

MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
