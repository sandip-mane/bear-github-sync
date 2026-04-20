# bear-github-sync

Sync your [Bear](https://bear.app) notes to a GitHub repo as Markdown. One-way per command, with attachments.

## What It Does

- **Export**: dumps all Bear notes as `.md` files with YAML frontmatter and pushes to GitHub; skips notes unchanged since the last export
- **Import**: pulls from GitHub and syncs notes to Bear; skips unchanged notes and asks before trashing removed notes or overwriting changed ones
- Syncs attachments (images, PDFs, etc.)

Each command is one-directional, so notes can never be accidentally deleted by a misfired bidirectional sync.

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
./bear.sh export    # Bear → GitHub
./bear.sh import    # GitHub → Bear (asks before trashing or overwriting notes)
./bear.sh update    # Update bear.sh to the latest version
```

Import auto-opens Bear if it isn't running.

## How It Works

**Export** reads Bear's SQLite database (read-only), writes each changed note as a `.md` file with frontmatter, copies attachments, deletes any repo files no longer in Bear, and pushes to GitHub. Notes whose `modified` timestamp already matches the repo are left untouched.

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

**Import** pulls from GitHub, compares each repo note's `modified` timestamp against Bear, and classifies notes as new / changed / unchanged / removed. It asks for confirmation before trashing removed notes, and separately before overwriting changed ones. Only new and (approved) changed notes are recreated via `bear://x-callback-url`, oldest-first to preserve Bear's sidebar order. Unchanged notes are left alone.

## Repo Structure

```
my-bear-notes/
├── notes/              # One .md file per note
├── attachments/        # Images/files organized by note
│   └── my-note/
│       └── screenshot.png
├── bear.sh             # The sync script
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

- Encrypted notes are skipped during export
- Import trashes and recreates new/changed notes, so those notes get new UUIDs (reconciled on the next export); unchanged notes keep their UUIDs
- Conflict strategy: export = Bear wins, import = repo wins

## License

MIT
