# Agent guidance

- Make focused changes, preserve unrelated work, and follow existing patterns.
- Manifests belong in `bucket/` with lowercase kebab-case filenames and valid Scoop JSON. Include `license`; add `autoupdate` and `persist` only when supported by verified release and data paths. Do not guess URLs or paths.
- Inspect archive contents before setting `bin`, `shortcuts`, or `extract_dir`. Shortcuts use `[relative executable path, human-readable title]`; omit platform tags.
- When adding or removing a manifest, update its `README.md` catalog entry with accurate details.
- For new manifests, run the app and verify its data locations before configuring `persist`.
- For manifest changes, run relevant checks: `.\bin\checkver.ps1 -Dir bucket -App <name>`, `.\bin\check-autoupdate.ps1 -ManifestPath bucket\<name>.json`, and `.\bin\check-manifest-install.ps1 -ManifestPath bucket\<name>.json`. Report checks that cannot run.
- For PowerShell changes, run related Pester tests with `.\bin\test.ps1`.
