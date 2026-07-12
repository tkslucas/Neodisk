# Contributing to Neodisk

Thanks for your interest. Bug reports, ideas, translations, and pull requests
are all welcome.

## Reporting issues

Open a [GitHub issue](https://github.com/tkslucas/Neodisk/issues) with your
Neodisk and macOS versions, steps to reproduce, and what you expected. For
security problems, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.

## Pull requests

Small fixes are fine to send directly. For anything larger, open an issue
first so we can agree on the approach before you spend time on it.

Before sending a PR:

```
swift build
swift test
```

Two hard rules:

- **Neodisk is read-only.** It never writes to, modifies, or deletes scanned
  files, and it makes no network requests. Any change that could break that
  will not be merged. See the read-only note in the README.
- **Keep the layering.** `NeodiskKit` stays UI-free, `TreemapKit` stays pure
  geometry. Do not reach across the target boundaries described in the README.

If your change is user-facing, update the string catalogs under
`Localization/` (English at minimum).

## License of contributions

Neodisk is GPL-3.0-or-later. So that the project can also be distributed
through channels whose terms are incompatible with the GPL, and can change its
license in the future without tracking down every past contributor, every
contribution carries a small extra grant. This does not change what you or
anyone else receives: the public still gets Neodisk under GPL-3.0-or-later,
with no added restrictions.

By submitting a contribution (a pull request, patch, or any code, docs,
translation, or other material) you agree that:

1. You wrote it, or otherwise have the right to submit it under these terms.
2. Your contribution is licensed to the project and to everyone else under
   GPL-3.0-or-later, the same as the rest of Neodisk.
3. You also grant the Neodisk maintainers and their successors and assigns a
   perpetual, worldwide, non-exclusive, royalty-free, irrevocable,
   transferable license to use, reproduce, modify, and distribute your
   contribution, and to relicense and sublicense it under other terms,
   including proprietary or commercial terms.
4. You grant the Neodisk maintainers, their successors and assigns, and
   everyone who receives the software a perpetual, worldwide, non-exclusive,
   royalty-free, irrevocable patent license to make, have made, use, offer for
   sale, sell, import, and otherwise transfer your contribution, for any patent
   claims you can license that your contribution, alone or combined with
   Neodisk, would otherwise infringe. This patent license also covers versions
   distributed under the other terms in point 3.
5. You keep the copyright to your contribution. This is a license grant, not a
   transfer of ownership.

If any part of your contribution was made in the course of employment, or your
employer otherwise has rights to work you create, you represent that you have
permission to submit it under these terms, or that your employer has waived
those rights for it. Otherwise, do not submit it.
