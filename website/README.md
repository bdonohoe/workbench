# Workbench website

A static site with no build step: plain HTML, CSS, and JavaScript. It's live
at https://workbenchapp.dev/, served by GitHub Pages from
the bench-releases repo, along with the update feed (`appcast.xml`). Every
copy of Workbench reads the feed at that address, so it stays there. New
releases themselves are made in
[workbench](https://github.com/mattbirchler/workbench/releases), the source
repo; the ones from before it went public stay in bench-releases.

## Publishing

- `make website` copies this folder into bench-releases and pushes it. Run it
  from main after merging website changes.
- `make publish` does the same copy with every app release.

Only the pages and `assets/` are copied (`scripts/sync-website.sh`), so the
update feed (`appcast.xml`) and the release-note images in bench-releases are
never touched. `privacy.html` and `support.html` replace the old ones at the
same URLs, which the App Store listing and the iPhone app link to.

```sh
cd website && python3 -m http.server 8787   # then open http://localhost:8787
```

## Pages

- `index.html`: the landing page. The floating icon is the app icon's own
  layers in CSS 3D, and the app window below it is HTML, not a screenshot.
- `releases.html`: the version history, loaded in the browser from both
  repos' releases on GitHub and merged, newest first. New releases show up on their own, with the same notes that
  `make publish` posts.
- `privacy.html` and `support.html`: the same text as `privacy.md` and
  `support.md` in bench-releases. If one changes, change the other.

## How it stays current

- **Download buttons** are pointed at the newest release's disk image, in
  whichever repo it is, once GitHub's list arrives. Until then, or if it
  doesn't, they use the address in the page: bench-releases'
  `releases/latest/download/Workbench.dmg`, which gives 0.10 build 68. That
  updates itself to the newest version on first launch.
- **Version history** loads from GitHub's API. Moving between pages reuses
  that list for up to 5 minutes, but a reload always asks GitHub again, and a
  tab Chrome or Safari restores from memory reloads if it's older than that.
- **Colors** are Workbench's Northern Lights theme, always dark. They're at
  the top of `assets/site.css`, taken from `BuiltInThemes.swift`.
- **Screenshots** in `assets/img/` are WebP. Show the app in Northern Lights,
  except where a shot is about the themes themselves.

GitHub allows 60 API requests an hour per visitor's IP address. The site makes
two per visit (one per repo) and keeps the result for 5 minutes, so ordinary visitors
never come near that limit.
