# Media Repository for aykhan.net

<div align="center">
  <img src="https://media.aykhan.net/assets/logos/aykhannet.ico" alt="Aykhan.net Logo">
</div>

## Media Subdomain - media.aykhan.net

The media subdomain, [media.aykhan.net](https://media.aykhan.net), is a specialized section of my website that functions as the centralized media storage and deployment platform. It houses various media assets used on [aykhan.net](https://aykhan.net), including images, GIFs, videos, icons, and other media files.

## How to Use the Media Assets

To use any of the media assets hosted in this repository, you can reference them directly from the subdomain [media.aykhan.net](https://media.aykhan.net). For example, to embed an image in your project, use the following URL:

```
https://media.aykhan.net/assets/images/example.jpg
```

Replace `example.jpg` with the filename of the specific image you want to use.

Thank you for visiting my media repository and exploring the media assets that make [aykhan.net](https://aykhan.net) a vibrant and engaging platform!

## Public media index (`media-index.json`)

`generate_index.py` produces two public, read-only metadata files consumed by the
[Aykhan Terminal Gateway](https://aykhan.net/terminal):

- **`media-index.json`** — every indexed public media file (`path`, `name`,
  `extension`, `type`, `sizeBytes`, `url`) plus the list of `folders`.
- **`build-report.json`** — `service`, `generatedAt`, `totalFiles`,
  `indexedFolders`, `skippedFolders`, and `notes`.

Run it from the repo root (it also refreshes the browsable `index.html` listings):

```
python generate_index.py
```

### Which folders are indexed

Indexing is **whitelist-based**. Only these top-level folders are scanned:

```
assets · thumbnails · notion-pages · achievements · books
```

…and only files with a public **media extension** (images, video, audio) are
included. Everything else is ignored.

### Security note — public metadata only

The index exposes metadata about files that are **already public** in this repo.
By design it **excludes** PDFs, HTML directory listings, hidden/dotfiles, `.env`,
secrets, and anything under `private`/`drafts`/`secrets`/`node_modules`. The
whitelist is opt-in, so a new folder is *not* indexed until it is explicitly
added — nothing sensitive is published by accident.
