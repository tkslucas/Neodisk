## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How you tested it

<!-- What you ran, and on which macOS version. For performance changes,
     include before and after numbers and how you measured them. -->

## Checklist

- [ ] `swift build` and `swift test` both pass on my branch
- [ ] Branch is rebased on current `main`
- [ ] Neodisk stays read-only: no writes to scanned files, no network requests
- [ ] Layering respected: `NeodiskKit` stays UI-free, `TreemapKit` stays pure geometry
- [ ] User-facing strings updated in `Localization/` (English at minimum)
- [ ] I have read and agree to the terms in [CONTRIBUTING.md](https://github.com/tkslucas/Neodisk/blob/main/CONTRIBUTING.md), including the relicensing grant
