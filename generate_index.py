import os
import json
import html
import subprocess
from datetime import datetime, timezone

# HTML template for the index.html file, with a signature comment
INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="icon" type="image/x-icon"
        href="https://res.cloudinary.com/dbriqxpaa/image/upload/v1680096853/Logo/logo-xl-ico_qzbf7d.ico" />
    <title>{title}</title>
    <script>
        // Apply saved theme before paint to avoid a flash. Dark is the default.
        (function () {{
            try {{
                if (localStorage.getItem('aykhan-listing-theme') === 'light') {{
                    document.documentElement.classList.add('light');
                }}
            }} catch (e) {{}}
        }})();
    </script>
    <style>
        /* Palette mirrors aykhan.net/terminal so all three properties match. */
        :root {{
            --bg: #0d1117;
            --panel: #11161d;
            --bar: #1c232c;
            --text: #c9d1d9;
            --muted: #6e7681;
            --accent: #f06449;
            --green: #3fb950;
            --link: #58a6ff;
            --border: #21262d;
            --selection: #234a6b;
            --mono: "SF Mono", "Fira Code", "JetBrains Mono", Menlo, Consolas, "Liberation Mono", monospace;
        }}
        html.light {{
            --bg: #ffffff;
            --panel: #f6f8fa;
            --bar: #eaeef2;
            --text: #1f2328;
            --muted: #656d76;
            --accent: #d03a1f;
            --green: #1a7f37;
            --link: #0969da;
            --border: #d0d7de;
            --selection: #ddf4ff;
        }}
        * {{ box-sizing: border-box; }}
        body {{
            margin: 0;
            min-height: 100vh;
            background: var(--bg);
            color: var(--text);
            font-family: var(--mono);
            font-size: 14px;
            line-height: 1.55;
            padding: 0;
        }}
        ::selection {{ background: var(--selection); }}
        .window {{
            width: 100%;
            min-height: 100vh;
            background: var(--panel);
            border: 0;
            border-radius: 0;
            overflow: hidden;
        }}
        .titlebar {{
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 11px 14px;
            background: var(--bar);
            border-bottom: 1px solid var(--border);
        }}
        .dot {{ width: 12px; height: 12px; border-radius: 50%; flex: 0 0 auto; }}
        .dot.red {{ background: #ff5f56; }}
        .dot.yellow {{ background: #ffbd2e; }}
        .dot.green {{ background: #27c93f; }}
        .titlebar-text {{
            margin-left: 6px;
            color: var(--muted);
            font-size: 12.5px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }}
        .crumb {{
            padding: 16px 18px 8px;
        }}
        .crumb h1 {{
            margin: 0;
            font-size: 1em;
            font-weight: 400;
            line-height: 1.7;
            color: var(--text);
            word-break: break-word;
        }}
        .crumb h1::before {{
            content: "$ ls ";
            color: var(--green);
        }}
        .crumb-current {{ color: var(--text); }}
        .crumb-sep {{ color: var(--muted); margin: 0 6px; }}
        table {{ width: 100%; border-collapse: collapse; }}
        thead th {{
            position: sticky;
            top: 0;
            text-align: left;
            font-weight: 600;
            font-size: 11px;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--muted);
            background: var(--panel);
            padding: 9px 14px;
            border-bottom: 1px solid var(--border);
        }}
        tbody td {{
            padding: 7px 14px;
            border-bottom: 1px solid var(--border);
            white-space: nowrap;
        }}
        tbody tr:last-child td {{ border-bottom: 0; }}
        tbody tr:hover {{ background: var(--selection); }}
        td.icon-col {{ width: 34px; text-align: center; }}
        td:nth-child(3) {{ color: var(--muted); }}
        td:nth-child(4) {{ color: var(--muted); font-size: 12.5px; }}
        a {{ color: var(--link); text-decoration: none; }}
        a:hover {{ color: var(--accent); text-decoration: underline; }}
        .theme-toggle {{
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: var(--panel);
            color: var(--text);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 8px 14px;
            font-family: var(--mono);
            font-size: 12.5px;
            cursor: pointer;
            z-index: 1000;
        }}
        .theme-toggle:hover {{ border-color: var(--accent); color: var(--accent); }}
        @media (max-width: 560px) {{
            thead th:nth-child(3), td:nth-child(3) {{ display: none; }}
        }}
    </style>
</head>
<body>
    <!-- Auto-generated by Python script -->
    <div class="window">
        <div class="titlebar">
            <span class="dot red"></span>
            <span class="dot yellow"></span>
            <span class="dot green"></span>
            <span class="titlebar-text">{title}</span>
        </div>
        <div class="crumb">
            <h1>{header_text}</h1>
        </div>
        <table>
            <thead>
                <tr>
                    <th class="icon-col">·</th>
                    <th>Name</th>
                    <th>Size</th>
                    <th>Last Modified</th>
                </tr>
            </thead>
            <tbody>
            {table_rows}
            </tbody>
        </table>
    </div>

    <button class="theme-toggle" type="button" onclick="__toggleTheme()">☾ dark</button>
    <script>
        (function () {{
            var KEY = 'aykhan-listing-theme';
            function label() {{
                var b = document.querySelector('.theme-toggle');
                if (!b) return;
                b.textContent = document.documentElement.classList.contains('light') ? '☀ light' : '☾ dark';
            }}
            window.__toggleTheme = function () {{
                var light = !document.documentElement.classList.contains('light');
                document.documentElement.classList.toggle('light', light);
                try {{ localStorage.setItem(KEY, light ? 'light' : 'dark'); }} catch (e) {{}}
                label();
            }};
            document.addEventListener('DOMContentLoaded', label);
        }})();
    </script>
</body>
</html>
"""

# Directories never listed in the browsable index.html tree. Mirrors the JSON
# indexer's deny-list so sensitive folders are never exposed, even if added later.
EXCLUDED_DIRS = [
    '.git', '.github', '__pycache__', 'node_modules',
    'private', 'drafts', 'secrets', '.secrets',
]

def is_auto_generated(file_path):
    """Check if the file contains the auto-generated signature"""
    if not os.path.exists(file_path):
        return False
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
        return '<!-- Auto-generated by Python script -->' in content

def format_size(size):
    """Convert bytes to a human-readable string"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0

def format_date(timestamp):
    """Format a timestamp as UTC so output is deterministic across machines."""
    dt_utc = datetime.fromtimestamp(timestamp, tz=timezone.utc)
    return dt_utc.strftime('%Y-%m-%d %H:%M UTC')

def _git_commit_times():
    """Map repo-relative POSIX path -> last commit time (UNIX seconds).

    One `git log` pass, newest commit first, so the first time a path appears is
    its most recent change. A \\x01 marker separates date lines from file paths.
    Returns {} when git or history is unavailable; callers then fall back to the
    filesystem mtime (git does not preserve per-file mtimes across checkouts)."""
    try:
        out = subprocess.run(
            ['git', 'log', '--no-renames', '--pretty=format:\x01%ct', '--name-only'],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return {}
    times = {}
    ts = None
    for line in out.splitlines():
        if line.startswith('\x01'):
            ts = int(line[1:])
        elif line and ts is not None:
            times.setdefault(line, ts)
    return times

def _commit_time_index():
    """Return (file_times, dir_times); a directory's time is the most recent
    commit time among the files it contains."""
    file_times = _git_commit_times()
    dir_times = {}
    for path, ts in file_times.items():
        d = os.path.dirname(path)
        while d:
            if dir_times.get(d, -1) < ts:
                dir_times[d] = ts
            d = os.path.dirname(d)
    return file_times, dir_times

def _modified_label(rel_path, fs_path, commit_times):
    """Last-modified label: git commit time when known, else filesystem mtime."""
    ts = commit_times.get(rel_path)
    if ts is None:
        ts = os.path.getmtime(fs_path)
    return format_date(ts)

def get_full_url(root, folder_path):
    """Generate a full URL based on the directory path relative to the root"""
    relative_path = os.path.relpath(root, folder_path)
    if relative_path == ".":
        return "media.aykhan.net"
    return f"media.aykhan.net/{relative_path.replace(os.sep, '/')}"

def build_breadcrumb(root, folder_path, host):
    """Return breadcrumb HTML: clickable ancestor links + the current segment."""
    rel = os.path.relpath(root, folder_path)
    parts = [] if rel == '.' else rel.replace(os.sep, '/').split('/')
    segments = [host] + parts
    depth = len(segments) - 1  # index of the current (last) segment
    crumbs = []
    for i, seg in enumerate(segments):
        up = depth - i  # how many directories to climb to reach this segment
        label = html.escape(seg)
        if up == 0:
            crumbs.append(f'<span class="crumb-current">{label}</span>')
        else:
            href = '../' * up + 'index.html'
            crumbs.append(f'<a href="{href}">{label}</a>')
    return '<span class="crumb-sep">/</span>'.join(crumbs)

def to_title_case(s):
    """Convert a string to title case, ensuring it is all lowercase."""
    return s.replace('/', ' ').lower().replace(' ', ' | ') 

def generate_index_html(folder_path):
    """
    Recursively generates or updates index.html files in each folder and subfolder,
    but skips files not auto-generated by this script and excludes certain folders.
    """
    file_times, dir_times = _commit_time_index()
    for root, dirs, files in os.walk(folder_path):
        # Skip excluded directories; sort so output order is deterministic.
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS)

        index_file_path = os.path.join(root, 'index.html')

        # Skip updating if index.html exists but was not auto-generated
        if 'index.html' in files and not is_auto_generated(index_file_path):
            print(f'Skipping {index_file_path} (manually created)')
            continue

        # Breadcrumb of clickable links; the current folder is the last segment.
        host = "media.aykhan.net"
        header_text = build_breadcrumb(root, folder_path, host)
        if root == folder_path:
            title = host
        else:
            title = html.escape(to_title_case(get_full_url(root, folder_path)))

        # Create list of items (folders and files) for the current folder
        table_rows = []

        # Add directories to the table
        for dir_name in dirs:
            dir_path = os.path.join(root, dir_name)
            rel_dir = os.path.relpath(dir_path, folder_path).replace(os.sep, '/')
            last_modified = _modified_label(rel_dir, dir_path, dir_times)
            safe_name = html.escape(dir_name)
            table_rows.append(
                f'<tr>'
                f'<td class="icon-col">📁</td>'
                f'<td><a href="{safe_name}/index.html">{safe_name}/</a></td>'
                f'<td>-</td>'
                f'<td>{last_modified}</td>'
                f'</tr>'
            )

        # Add files to the table (skip the index.html file); sort for deterministic order.
        for file_name in sorted(files):
            if file_name == "index.html":
                continue
            file_path = os.path.join(root, file_name)
            rel_file = os.path.relpath(file_path, folder_path).replace(os.sep, '/')
            file_size = format_size(os.path.getsize(file_path))
            last_modified = _modified_label(rel_file, file_path, file_times)
            safe_name = html.escape(file_name)
            table_rows.append(
                f'<tr>'
                f'<td class="icon-col">📄</td>'
                f'<td><a href="{safe_name}">{safe_name}</a></td>'
                f'<td>{file_size}</td>'
                f'<td>{last_modified}</td>'
                f'</tr>'
            )

        # Join the table rows as HTML
        table_rows_html = "\n        ".join(table_rows)

        # Render the final HTML for the index.html file
        index_html_content = INDEX_HTML_TEMPLATE.format(
            title=title,
            header_text=header_text,
            table_rows=table_rows_html,
        )

        # Write or overwrite index.html in the current folder with utf-8 encoding
        with open(index_file_path, 'w', encoding='utf-8') as index_file:
            index_file.write(index_html_content)

        print(f'Updated {index_file_path}')

# ---------------------------------------------------------------------------
# Public media index (read-only, whitelist-based)
# ---------------------------------------------------------------------------
# Only the top-level folders in WHITELIST_DIRS are scanned, and only files with
# a public media extension (images / video / audio) are indexed. Everything else
# -- hidden files, .env, secrets, HTML directory listings, and PDFs -- is
# ignored. The generated media-index.json therefore exposes public metadata only.

BASE_URL = "https://media.aykhan.net"

WHITELIST_DIRS = ["assets", "thumbnails", "notion-pages", "achievements", "books"]

DENY_DIR_NAMES = {
    ".git", ".github", "__pycache__", "node_modules",
    "private", "drafts", "secrets", ".secrets",
}

# Extension -> MIME type. Acts as the file whitelist: anything not listed here
# (e.g. .pdf, .html, .py) is never indexed.
MEDIA_TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
    ".ico": "image/x-icon", ".bmp": "image/bmp", ".avif": "image/avif",
    ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime",
    ".m4v": "video/x-m4v",
    ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4",
    ".ogg": "audio/ogg", ".flac": "audio/flac",
}


def _iter_media_files():
    """Yield (path, ext) for whitelisted media files in whitelisted folders."""
    for top in WHITELIST_DIRS:
        if not os.path.isdir(top):
            continue
        for root, dirs, files in os.walk(top):
            # prune hidden + denied directories in place
            dirs[:] = [d for d in dirs
                       if not d.startswith('.') and d not in DENY_DIR_NAMES]
            for name in files:
                if name.startswith('.'):
                    continue
                ext = os.path.splitext(name)[1].lower()
                if ext in MEDIA_TYPES:
                    yield os.path.join(root, name), ext


def generate_media_index():
    """Write media-index.json + build-report.json from whitelisted folders only."""
    files_out = []
    folders = set()
    for path, ext in sorted(_iter_media_files()):
        rel = path.replace(os.sep, '/').lstrip('./')
        folders.add(os.path.dirname(rel))
        files_out.append({
            "path": rel,
            "name": os.path.basename(rel),
            "extension": ext,
            "type": MEDIA_TYPES[ext],
            "sizeBytes": os.path.getsize(path),
            "url": f"{BASE_URL}/{rel}",
        })

    generated_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    folders = sorted(f for f in folders if f)

    index = {
        "service": "media",
        "generatedAt": generated_at,
        "baseUrl": BASE_URL,
        "totalFiles": len(files_out),
        "folders": folders,
        "files": files_out,
    }
    with open("media-index.json", "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2, ensure_ascii=False)

    indexed_top = sorted({f["path"].split('/')[0] for f in files_out})
    all_top = sorted(d for d in os.listdir('.') if os.path.isdir(d))
    skipped = [d for d in all_top
               if d not in indexed_top and d not in DENY_DIR_NAMES]

    report = {
        "service": "media",
        "generatedAt": generated_at,
        "totalFiles": len(files_out),
        "indexedFolders": indexed_top,
        "skippedFolders": skipped,
        "notes": [
            "Whitelist-based: only top-level folders in WHITELIST_DIRS are scanned.",
            "Only public media extensions are indexed (images, video, audio).",
            "PDFs, HTML listings, hidden files, .env and secrets are excluded.",
            "Indexed files are already public; this index exposes metadata only.",
        ],
    }
    with open("build-report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print(f"Wrote media-index.json ({len(files_out)} files) and build-report.json")


if __name__ == "__main__":
    root_folder = '.'
    generate_index_html(root_folder)
    generate_media_index()
