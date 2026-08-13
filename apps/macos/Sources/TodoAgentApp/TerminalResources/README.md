This directory is populated by `scripts/setup-ghostty.sh`.

The generated `ghostty/` and `terminfo/` directories are ignored by Git. Their
sibling layout is required by libghostty. Do not move `terminfo` under
`ghostty`.

`ThirdPartyLicenses/` is committed and bundled independently of generated
artifacts so every exact dependency license remains available in clean source
checkouts and release builds.
