# oz introduction site

A buildless English/Chinese site for GitHub Pages at
<https://nit-tin.github.io/oz/>. Product screenshots are copies of the current
README captures: real oz, with an idle Agent panel rather than simulated
model output. The original documentation and screenshot files are not changed.

## Preview and checks

```sh
python3 website/check.py
node --check website/site.js
python3 website/build.py --version v0.4.0
python3 website/check.py .verify/website
python3 -m http.server 4173 --bind 127.0.0.1 --directory .verify/website
```

Open <http://127.0.0.1:4173/>. Relative resource paths also work when the
artifact is served under the GitHub project prefix `/oz/`.

With Expect installed, open the preview and run the saved adversarial checks:

```sh
expect-cli open http://127.0.0.1:4173/
expect-cli playwright "return await ($(cat website/browser-check.js))({page,context});"
```

The checks cover four viewport widths in both languages, screenshot and
Agent tabs (including keyboard navigation), actual clipboard writing and
denied-copy fallback, all four download architectures, dialog focus/close,
query/hash preservation, blocked storage and a JavaScript-disabled visitor.
Accessibility audits also require review of manual-check results: focus
rings, tab keyboard handlers and sensory-language heuristics cannot all be
verified by a static scanner.

## Publishing

The repository's Settings → Pages source is **GitHub Actions**.
`.github/workflows/pages.yml` checks and packages this directory, then uses
the official GitHub Pages actions. PRs validate and upload an artifact;
only `master` or a published release deploys to production. A manual run
from `master` can redeploy. The release badge is filled from the latest
published release, and archive links use `/releases/latest/download/`.

Only the explicit public file list and `assets/` go into the artifact.
Development scripts, local audit logs, editor code and repository settings
are excluded. No Node dependencies, visitor API requests, analytics,
third-party scripts or remote font services are used.

Instrument Serif and DM Sans are self-hosted in WOFF2 format. Their SIL Open
Font License notices are included beside the font files. The site code is
covered by the repository's MIT license.
