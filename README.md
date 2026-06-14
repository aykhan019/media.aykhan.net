<div align="center">

<img src="https://media.aykhan.net/assets/logos/aykhannet-transparent-bg.svg" alt="aykhan.net logo" width="120" />

# media.aykhan.net

**Public, read‑only media host for the aykhan.net ecosystem — images, video, audio and icons, plus a whitelist‑generated metadata index.**

[![Live](https://img.shields.io/badge/live-media.aykhan.net-235aa6?style=flat-square)](https://media.aykhan.net)
[![Index](https://img.shields.io/badge/index-media--index.json-1c1d25?style=flat-square)](https://media.aykhan.net/media-index.json)
[![Deploy](https://img.shields.io/badge/hosting-GitHub%20Pages-222?style=flat-square&logo=github)](https://pages.github.com)
[![Generator](https://img.shields.io/badge/generator-Python%203-f06449?style=flat-square&logo=python&logoColor=white)](./generate_index.py)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](./LICENSE)

</div>

---

## Overview

`media.aykhan.net` is the centralized media CDN for [aykhan.net](https://aykhan.net) and its
sibling services. It serves static assets directly over its own domain and publishes a
machine‑readable index of everything it hosts, consumed by the
[Terminal Gateway](https://aykhan.net/terminal).

It is one of three independent, GitHub Pages–hosted repositories:

| Domain | Role |
| --- | --- |
| [aykhan.net](https://aykhan.net) | E‑portfolio + Terminal Gateway |
| **[media.aykhan.net](https://media.aykhan.net)** | **Public media host + `media-index.json`** |
| [data.aykhan.net](https://data.aykhan.net) | Static JSON "API" + `data-index.json` |

## Using the assets

Reference any hosted file directly by its URL:

```
https://media.aykhan.net/assets/images/example.jpg
```

```html
<img src="https://media.aykhan.net/assets/logos/aykhannet.ico" alt="logo" />
```

## The public index

[`generate_index.py`](./generate_index.py) produces two public, read‑only metadata files and
refreshes the browsable `index.html` listings:

| File | Contents |
| --- | --- |
| **`media-index.json`** | Every indexed file — `path`, `name`, `extension`, `type`, `sizeBytes`, `url` — plus the list of `folders`. |
| **`build-report.json`** | `service`, `generatedAt`, `totalFiles`, `indexedFolders`, `skippedFolders`, `notes`. |

```bash
python generate_index.py    # run from the repo root; no third-party dependencies
```

### What gets indexed

Indexing is **whitelist‑based** — a folder or file type is invisible to the index until it
is explicitly allowed.

- **Scanned top‑level folders:** `assets` · `thumbnails` · `notion-pages` · `achievements` · `books`
- **Allowed file types** (the extension map doubles as the file whitelist):
  - **Images** — `.png` `.jpg` `.jpeg` `.gif` `.webp` `.svg` `.ico` `.bmp` `.avif`
  - **Video** — `.mp4` `.webm` `.mov` `.m4v`
  - **Audio** — `.mp3` `.wav` `.m4a` `.ogg` `.flac`

Anything else (`.pdf`, `.html`, `.py`, …) is never indexed.

## Security model — public metadata only

This repository is **read‑only and public by design**. The index publishes **metadata
only** (`path` / `name` / `url` / `sizeBytes`); it never inlines file contents. The
generator explicitly excludes hidden/dotfiles and any directory named:

```
.git · .github · __pycache__ · node_modules · private · drafts · secrets · .secrets
```

There are no tokens, API keys, secrets, `.env` files, uploads, or authentication anywhere
in this system.

## Project structure

```
media.aykhan.net/
├── assets/                 # Primary media (images, logos, video, audio)
├── thumbnails/             # Generated/scaled previews
├── notion-pages/           # Exported Notion media
├── achievements/  books/   # Section-specific media
├── generate_index.py       # Builds media-index.json + build-report.json + index.html
├── test_generate_index.py  # Generator tests
├── media-index.json        # Generated — public file index
├── build-report.json       # Generated — build summary
├── index.html              # Generated — browsable listing
└── CNAME                   # media.aykhan.net
```

## License

Released under the [MIT License](./LICENSE) © 2023 Aykhan Ahmadzada.
