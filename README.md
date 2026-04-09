# bear-github-sync

Sync your [Bear](https://bear.app) notes to a GitHub repo as Markdown. Bidirectional, with attachments.

## What It Does

- Exports Bear notes as `.md` files with YAML frontmatter (title, tags, dates)
- Imports markdown files back into Bear
- Syncs attachments (images, PDFs, etc.)
- Tracks changes — only syncs what's different
- Handles deletions in both directions
- Commits and pushes automatically

## Requirements

- macOS with [Bear](https://bear.app)
- [jq](https://jqlang.github.io/jq/) — `brew install jq`
- `git`, `sqlite3`, `python3` (pre-installed on macOS)

## Setup

```bash
# Clone this repo as your notes repo
git clone https://github.com/sandip-mane/bear-github-sync.git my-bear-notes
cd my-bear-notes

# Create your own private repo and point to it
gh repo create my-bear-notes --private
git remote set-url origin git@github.com:<your-username>/my-bear-notes.git

# Run first export
./bear.sh export
```

## Usage

```bash
# Full sync — pull remote changes into Bear, then push Bear changes to repo
./bear.sh sync

# One-way operations
./bear.sh export    # Bear → GitHub
./bear.sh import    # GitHub → Bear

# Preview changes without doing anything
./bear.sh sync --dry-run
./bear.sh export --dry-run
./bear.sh import --dry-run
```

## How It Works

**Export** reads Bear's SQLite database (read-only), writes each note as a `.md` file with frontmatter, copies attachments, and pushes to GitHub.

```yaml
---
uuid: EE068501-1557-47D2-8E79-5FB3DE18A403
title: "My Note"
tags: ["work", "ideas"]
created: 2024-01-15T10:30:00
modified: 2024-03-20T14:22:00
---
Your note content here...
```

**Import** pulls from GitHub, compares checksums against a manifest, and creates/updates notes in Bear via `bear://x-callback-url`.

**Sync** runs import first (so remote changes land in Bear), then export (so local Bear changes go to the repo).

A `.manifest.json` tracks sync state so unchanged notes are skipped.

## Repo Structure

```
my-bear-notes/
├── notes/              # One .md file per note
├── attachments/        # Images/files organized by note
│   └── my-note/
│       └── screenshot.png
├── .manifest.json      # Sync state (auto-managed, gitignored)
├── bear.sh        # The sync script
└── README.md
```

## Configuration

Works out of the box with standard Bear installations. To override paths, create a `.bear-sync.conf` file:

```bash
BEAR_DB="$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite"
BEAR_FILES="$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/Local Files/Note Images"
REPO_DIR="$HOME/Work/my-bear-notes"
```

## Limitations

- Bear must be open for import to work
- Encrypted notes are skipped during export
- Updated notes on import are trashed and recreated (Bear assigns new UUIDs, reconciled on next export)
- Conflict strategy: import = repo wins, export = Bear wins

## License

MIT
