# Convos Docs Site

A static HTML preview of the documentation revamp. The goal is to convert the
existing `docs/adr/*.md` and related write-ups into diagram-rich pages organized
around the systems they describe.

## Layout

```
docs/site/
├── index.html              Table of contents (entry point)
├── assets/
│   ├── tokens.css          Design tokens (mirrored from convos-assistants)
│   └── site.css            Layout + components
├── design/index.html       Design library preview
└── adr/                    Per-ADR HTML pages (next step — currently empty)
```

## Preview locally

The pages are static — no build step. Either:

```sh
open docs/site/index.html
```

or run a tiny server from the repo root so relative links and fonts behave like
a deployed site:

```sh
python3 -m http.server 4567 --directory docs/site
# then visit http://localhost:4567
```

## Design

- Tokens (`assets/tokens.css`) mirror `convos-assistants/dashboard/src/app/globals.css`
  and `convos-assistants/pool/frontend/admin.css` so this site reads as part of
  the same family.
- Layout language (numbered sections, anchor-linked categories, arrow CTAs,
  generous whitespace) is borrowed from
  [`thariqs.github.io/html-effectiveness`](https://thariqs.github.io/html-effectiveness/).
- Font is Inter, with the iOS system stack as a fallback.

## What's mocked vs. real

- The **table of contents** is real-but-mock: every ADR card links to a page
  under `adr/` that doesn't exist yet. The cards reflect the real titles and
  statuses pulled from `docs/adr/*.md` on the `dev` branch.
- The **design library** is real — every token, type style, and component on
  that page is the one used by the table of contents.
- The **overviews** and **plans** sections list categories we want to cover
  but the destination pages are not written yet.

## Next steps

1. Pick one ADR (likely 001 — invite system) and port it to HTML, validating
   each technical claim against the current code in `ConvosCore`.
2. Build the diagram components needed for that ADR. Add anything reusable to
   the design library.
3. Repeat — using each ported ADR as a chance to refresh outdated claims.
