# bear-github-sync

Sync your [Bear](https://bear.app) notes to a GitHub repo as Markdown files. Bidirectional — export from Bear, import back from the repo. Includes attachments.

## Features

- Export all Bear notes as `.md` files with YAML frontmatter (title, tags, dates)
- Import markdown files back into Bear via x-callback-url
- Track changes with a manifest — only sync what changed
- Attachments (images, files) synced alongside notes
- Deletion sync in both directions
- Dry-run mode to preview changes
- Git commit and push built-in

## Requirements

- macOS with [Bear](https://bear.app) installed
- `jq` — install with `brew install jq`
- `git`, `sqlite3`, `python3`, `shasum` (all pre-installed on macOS)

## Quick Start

```bash
# 1. Create a private repo on GitHub for your notes, clone it
gh repo create my-bear-notes --private --clone
cd my-bear-notes

# 2. Copy the scripts into your repo
cp /path/to/bear-github-sync/bear-sync.sh .
cp /path/to/bear-github-sync/sync.sh .
chmod +x bear-sync.sh sync.sh

# 3. Initialize
./bear-sync.sh init

# 4. Export your notes
./bear-sync.sh export

# 5. Push
git push
```

Or after initial setup, just run:

```bash
./sync.sh    # import + export + push in one shot
```

## Usage

```bash
./bear-sync.sh init              # Create repo structure
./bear-sync.sh export            # Bear → repo → git push
./bear-sync.sh import            # git pull → repo → Bear
./bear-sync.sh sync              # Export then import
./bear-sync.sh export --dry-run  # Preview what would change
./bear-sync.sh import --dry-run
./sync.sh                        # Import then export (full sync)
```

## How It Works

### Export (Bear → GitHub)

1. Reads Bear's SQLite database directly (read-only)
2. Converts each note to Markdown with YAML frontmatter:
   ```yaml
   ---
   uuid: EE068501-1557-47D2-8E79-5FB3DE18A403
   title: "My Note Title"
   tags: ["work", "ideas"]
   created: 2024-01-15T10:30:00
   modified: 2024-03-20T14:22:00
   ---
   ```
3. Copies attachments to `attachments/<note-name>/`
4. Rewrites image paths so they render on GitHub
5. Commits and pushes

### Import (GitHub → Bear)

1. Pulls latest from GitHub
2. Compares file checksums against the manifest
3. Creates new or updated notes via `bear://x-callback-url/create`
4. Updated notes are trashed and recreated (Bear limitation)
5. Deleted files in the repo trigger note trashing in Bear

### Manifest

A `.manifest.json` file tracks sync state (UUIDs, checksums, timestamps). This enables incremental sync — unchanged notes are skipped.

## Repo Structure

```
your-notes-repo/
├── notes/              # Markdown files (one per note)
│   ├── my-note.md
│   └── another-note.md
├── attachments/        # Images and files by note
│   └── my-note/
│       └── screenshot.png
├── .manifest.json      # Sync state (auto-managed)
├── .bear-sync.conf     # Optional config overrides
├── bear-sync.sh        # Main script
└── sync.sh             # One-shot sync wrapper
```

## Configuration

The script uses sensible defaults for standard Bear installations. To override, create `.bear-sync.conf`:

```bash
BEAR_DB="$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite"
BEAR_FILES="$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/Local Files/Note Images"
REPO_DIR="$HOME/Work/my-bear-notes"
```

## Known Limitations

- **Bear must be open** for import (x-callback-url requires the app to be running)
- **Encrypted notes** are skipped during export
- **Updated notes on import** are trashed and recreated — Bear assigns new UUIDs, which are reconciled on the next export
- **Conflict strategy**: export = Bear wins, import = repo wins
- **x-callback-url is fire-and-forget** — the script uses sleep delays between operations; on very slow machines, increase the delay in the script

## License

MIT
