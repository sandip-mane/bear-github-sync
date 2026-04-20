#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Configuration (override via .bear-sync.conf if needed) ---

BEAR_DB="${BEAR_DB:-$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite}"
BEAR_FILES="${BEAR_FILES:-$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/Local Files/Note Images}"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

[[ -f "$SCRIPT_DIR/.bear-sync.conf" ]] && source "$SCRIPT_DIR/.bear-sync.conf"

NOTES_DIR="$REPO_DIR/notes"
ATTACH_DIR="$REPO_DIR/attachments"
COREDATA_EPOCH=978307200

# --- Helper Functions ---

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 -]//g; s/  */ /g; s/ /-/g; s/^-//; s/-$//'
}

coredata_to_iso() {
    local ts="$1"
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        echo "unknown"
        return
    fi
    date -r "$(echo "$ts + $COREDATA_EPOCH" | bc | cut -d. -f1)" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "unknown"
}

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().rstrip('\n'),safe=''))" <<< "$1"
}

bear_is_running() { pgrep -x "Bear" > /dev/null 2>&1; }

ensure_bear_running() {
    if bear_is_running; then return 0; fi
    log "Bear is not running. Opening Bear..."
    open -a "Bear"
    local waited=0
    while ! bear_is_running; do
        sleep 1
        waited=$((waited + 1))
        if (( waited >= 15 )); then
            err "Bear did not start within 15 seconds"
        fi
    done
    sleep 2
    log "Bear is ready"
}

log() { echo "[bear] $*"; }
warn() { echo "[bear] WARNING: $*" >&2; }
err() { echo "[bear] ERROR: $*" >&2; exit 1; }

# --- SQL Queries ---

query_bear_notes() {
    sqlite3 -separator $'\t' "$BEAR_DB" "
        SELECT n.ZUNIQUEIDENTIFIER, n.ZTITLE, n.ZCREATIONDATE,
               n.ZMODIFICATIONDATE, n.ZENCRYPTED,
               COALESCE(GROUP_CONCAT(t.ZTITLE, ','), '')
        FROM ZSFNOTE n
        LEFT JOIN Z_5TAGS z ON z.Z_5NOTES = n.Z_PK
        LEFT JOIN ZSFNOTETAG t ON z.Z_13TAGS = t.Z_PK
        WHERE n.ZTRASHED = 0 AND n.ZPERMANENTLYDELETED = 0
        GROUP BY n.Z_PK ORDER BY n.ZTITLE;"
}

query_note_text() {
    local safe_uuid
    safe_uuid=$(printf '%s' "$1" | sed "s/'/''/g")
    sqlite3 "$BEAR_DB" "SELECT ZTEXT FROM ZSFNOTE WHERE ZUNIQUEIDENTIFIER = '$safe_uuid';"
}

query_note_files() {
    local safe_uuid
    safe_uuid=$(printf '%s' "$1" | sed "s/'/''/g")
    sqlite3 -separator $'\t' "$BEAR_DB" "
        SELECT f.ZUNIQUEIDENTIFIER, f.ZFILENAME FROM ZSFNOTEFILE f
        JOIN ZSFNOTE n ON f.ZNOTE = n.Z_PK
        WHERE n.ZUNIQUEIDENTIFIER = '$safe_uuid' AND f.ZPERMANENTLYDELETED = 0;"
}

# --- Text Processing ---

strip_bear_title_line() { echo "$1" | sed '1{/^# /d;}'; }

strip_tag_markers() { echo "$1" | sed -E 's/#([a-zA-Z0-9/_-]+)#//g'; }

build_frontmatter() {
    local uuid="$1" title="$2" tags="$3" created="$4" modified="$5"
    local tags_yaml="[]"
    [[ -n "$tags" ]] && tags_yaml=$(echo "$tags" | tr ',' '\n' | sort -u | jq -R . | jq -sc .)
    local escaped_title="${title//\\/\\\\}"
    escaped_title="${escaped_title//\"/\\\"}"
    printf -- '---\nuuid: %s\ntitle: "%s"\ntags: %s\ncreated: %s\nmodified: %s\n---\n' \
        "$uuid" "$escaped_title" "$tags_yaml" "$created" "$modified"
}

rewrite_images_for_export() {
    echo "$1" | sed -E "s|!\[([^]]*)\]\(([^/)][^)]*)\)|![\1](../attachments/${2}/\2)|g"
}

extract_frontmatter() {
    awk 'BEGIN{c=0} /^---$/{c++; if(c<=2) next} c==1{print}' "$1"
}

parse_frontmatter_field() {
    echo "$1" | grep "^${2}:" | sed "s/^${2}: *//" | sed 's/^"//;s/"$//'
}

parse_frontmatter_tags() {
    echo "$1" | grep "^tags:" | sed 's/^tags: *//' | jq -r '.[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

strip_frontmatter() {
    awk 'BEGIN{c=0} /^---$/{c++; if(c<=2) next} c>=2{print}' "$1"
}

rewrite_images_for_import() {
    local abs_attach_dir="$ATTACH_DIR/$2"
    if [[ -d "$abs_attach_dir" ]]; then
        echo "$1" | sed -E "s|!\[([^]]*)\]\(\.\./attachments/${2}/([^)]*)\)|![\1](file://${abs_attach_dir}/\2)|g"
    else
        echo "$1" | sed -E "s|!\[([^]]*)\]\(\.\./attachments/${2}/([^)]*)\)|![\1](\2)|g"
    fi
}

# --- Attachment Export ---

export_attachments() {
    local note_uuid="$1" slug="$2"
    local dest_dir="$ATTACH_DIR/$slug"

    local file_uuid filename
    while IFS=$'\t' read -r file_uuid filename; do
        [[ -z "$file_uuid" ]] && continue
        local src="$BEAR_FILES/$file_uuid/$filename"
        if [[ ! -f "$src" ]]; then
            warn "Attachment not found: $src"
            continue
        fi
        mkdir -p "$dest_dir"
        cp "$src" "$dest_dir/$filename"
    done < <(query_note_files "$note_uuid")

    if [[ -d "$dest_dir" ]]; then
        local current_files
        current_files=$(query_note_files "$note_uuid" | cut -f2)
        for existing in "$dest_dir"/*; do
            [[ -f "$existing" ]] || continue
            local bname
            bname=$(basename "$existing")
            echo "$current_files" | grep -qF "$bname" || rm "$existing"
        done
        rmdir "$dest_dir" 2>/dev/null || true
    fi
}

# --- Commands ---

cmd_export() {
    log "Exporting..."
    [[ -f "$BEAR_DB" ]] || err "Bear database not found at: $BEAR_DB"
    mkdir -p "$NOTES_DIR" "$ATTACH_DIR"

    local written_files used_slugs
    written_files=$(mktemp)
    used_slugs=$(mktemp)
    trap "rm -f '$written_files' '$used_slugs'" EXIT

    local changed=0 unchanged=0 removed=0
    while IFS=$'\t' read -r uuid title created_ts modified_ts encrypted tags; do
        if [[ "$encrypted" == "1" ]]; then
            warn "Skipping encrypted note: $title"
            continue
        fi

        local slug
        slug=$(slugify "$title")
        [[ -z "$slug" ]] && slug="untitled"

        while grep -qx "$slug" "$used_slugs" 2>/dev/null; do
            local i=2 base_slug="$slug"
            while grep -qx "${base_slug}-${i}" "$used_slugs" 2>/dev/null; do i=$((i + 1)); done
            slug="${base_slug}-${i}"
        done
        echo "$slug" >> "$used_slugs"

        local filename="${slug}.md"
        echo "$filename" >> "$written_files"

        local modified
        modified=$(coredata_to_iso "$modified_ts")

        local existing_file="$NOTES_DIR/$filename"
        if [[ -f "$existing_file" ]]; then
            local existing_fm existing_uuid existing_modified
            existing_fm=$(extract_frontmatter "$existing_file")
            existing_uuid=$(parse_frontmatter_field "$existing_fm" "uuid")
            existing_modified=$(parse_frontmatter_field "$existing_fm" "modified")
            if [[ "$existing_uuid" == "$uuid" && "$existing_modified" == "$modified" ]]; then
                unchanged=$((unchanged + 1))
                continue
            fi
        fi

        local created text body frontmatter
        created=$(coredata_to_iso "$created_ts")
        text=$(query_note_text "$uuid")
        body=$(strip_bear_title_line "$text")
        body=$(strip_tag_markers "$body")
        body=$(rewrite_images_for_export "$body" "$slug")
        frontmatter=$(build_frontmatter "$uuid" "$title" "$tags" "$created" "$modified")

        printf '%s\n%s\n' "$frontmatter" "$body" > "$NOTES_DIR/$filename"
        export_attachments "$uuid" "$slug"
        changed=$((changed + 1))
    done < <(query_bear_notes)

    # Remove files not in Bear
    for f in "$NOTES_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        if ! grep -qx "$(basename "$f")" "$written_files"; then
            rm -f "$f"
            removed=$((removed + 1))
        fi
    done

    # Remove orphaned attachment dirs
    for d in "$ATTACH_DIR"/*/; do
        [[ -d "$d" ]] || continue
        grep -qx "$(basename "$d").md" "$written_files" || rm -rf "$d"
    done

    cd "$REPO_DIR"
    git add notes/ attachments/
    [[ -f .manifest.json ]] && git rm -f .manifest.json 2>/dev/null || true
    if ! git diff --cached --quiet; then
        git commit -m "bear export: $changed changed, $removed removed"
        git remote get-url origin > /dev/null 2>&1 && git push && log "Pushed to origin"
    else
        log "No changes to commit"
    fi
    log "Export complete: $changed changed, $unchanged unchanged, $removed removed"
}

cmd_import() {
    log "Importing..."
    ensure_bear_running

    cd "$REPO_DIR"
    git remote get-url origin > /dev/null 2>&1 && { git pull --rebase 2>/dev/null || git pull; }

    local bear_state new_notes changed_notes repo_uuids to_trash to_create
    bear_state=$(mktemp)
    new_notes=$(mktemp)
    changed_notes=$(mktemp)
    repo_uuids=$(mktemp)
    to_trash=$(mktemp)
    to_create=$(mktemp)
    trap "rm -f '$bear_state' '$new_notes' '$changed_notes' '$repo_uuids' '$to_trash' '$to_create'" EXIT

    # Snapshot Bear state: uuid \t modified_iso \t title
    while IFS=$'\t' read -r uuid title _created modified_ts encrypted _tags; do
        [[ "$encrypted" == "1" ]] && continue
        local modified_iso
        modified_iso=$(coredata_to_iso "$modified_ts")
        printf '%s\t%s\t%s\n' "$uuid" "$modified_iso" "$title" >> "$bear_state"
    done < <(query_bear_notes)

    # Categorize repo files into NEW / CHANGED / UNCHANGED
    local unchanged=0
    for mdfile in "$NOTES_DIR"/*.md; do
        [[ -f "$mdfile" ]] || continue
        local fm uuid title modified
        fm=$(extract_frontmatter "$mdfile")
        uuid=$(parse_frontmatter_field "$fm" "uuid")
        title=$(parse_frontmatter_field "$fm" "title")
        modified=$(parse_frontmatter_field "$fm" "modified")
        [[ -n "$uuid" ]] && echo "$uuid" >> "$repo_uuids"

        local bear_modified
        bear_modified=$(grep -E "^${uuid}"$'\t' "$bear_state" 2>/dev/null | cut -f2 | head -1)

        if [[ -z "$bear_modified" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$modified" "$uuid" "$title" "$mdfile" >> "$new_notes"
        elif [[ "$bear_modified" == "$modified" ]]; then
            unchanged=$((unchanged + 1))
        else
            printf '%s\t%s\t%s\t%s\n' "$modified" "$uuid" "$title" "$mdfile" >> "$changed_notes"
        fi
    done

    # Bear notes not in repo -> REMOVED
    while IFS=$'\t' read -r uuid _mod title; do
        grep -qx "$uuid" "$repo_uuids" 2>/dev/null && continue
        printf '%s\t%s\n' "$uuid" "$title" >> "$to_trash"
    done < "$bear_state"

    # Prompt: trash REMOVED
    local proceed_trash=false trashed=0
    if [[ -s "$to_trash" ]]; then
        log "The following notes will be trashed from Bear:"
        while IFS=$'\t' read -r _uuid title; do
            log "  - $title"
        done < "$to_trash"
        printf "[bear] Proceed? [y/N] "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            proceed_trash=true
        else
            log "Skipped trashing notes"
        fi
    fi

    # Prompt: overwrite CHANGED
    local proceed_overwrite=false
    if [[ -s "$changed_notes" ]]; then
        log "The following notes will be overwritten in Bear:"
        while IFS=$'\t' read -r _mod _uuid title _file; do
            log "  - $title"
        done < "$changed_notes"
        printf "[bear] Proceed? [y/N] "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            proceed_overwrite=true
        else
            log "Skipped overwriting notes"
            : > "$changed_notes"
        fi
    fi

    # Execute: trash REMOVED
    if $proceed_trash; then
        while IFS=$'\t' read -r uuid title; do
            open "bear://x-callback-url/trash?id=${uuid}&show_window=no" 2>/dev/null
            sleep 1
            log "Trashed: $title"
            trashed=$((trashed + 1))
        done < "$to_trash"
    fi

    # Execute: trash CHANGED (before recreating)
    if $proceed_overwrite; then
        while IFS=$'\t' read -r _mod uuid _title _file; do
            open "bear://x-callback-url/trash?id=${uuid}&show_window=no" 2>/dev/null
            sleep 1
        done < "$changed_notes"
    fi

    local new_count=0 overwritten=0
    [[ -s "$new_notes" ]] && new_count=$(wc -l < "$new_notes" | tr -d ' ')
    [[ -s "$changed_notes" ]] && overwritten=$(wc -l < "$changed_notes" | tr -d ' ')

    # Create NEW + (approved) CHANGED in ascending modified order
    # Ordering note: Bear sorts by modification date (newest first). Processing
    # oldest-first means the most-recently-modified note gets the newest "now"
    # timestamp, preserving the relative order shown in Bear's sidebar.
    cat "$new_notes" "$changed_notes" 2>/dev/null | sort > "$to_create"

    while IFS=$'\t' read -r _mod _uuid title mdfile; do
        [[ -z "$mdfile" ]] && continue

        local filename slug fm tags body
        filename=$(basename "$mdfile")
        slug="${filename%.md}"
        fm=$(extract_frontmatter "$mdfile")
        tags=$(parse_frontmatter_tags "$fm")
        body=$(strip_frontmatter "$mdfile")
        body=$(rewrite_images_for_import "$body" "$slug")

        local encoded_title encoded_tags encoded_body
        encoded_title=$(urlencode "$title")
        encoded_tags=$(urlencode "$tags")
        encoded_body=$(urlencode "$body")
        open "bear://x-callback-url/create?title=${encoded_title}&text=${encoded_body}&tags=${encoded_tags}&show_window=no&open_note=no" 2>/dev/null
        sleep 1.5
        log "Imported: $title"
    done < "$to_create"

    log "Import complete: $new_count new, $overwritten overwritten, $trashed trashed, $unchanged unchanged"
}

# --- Argument Parsing ---

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    export)  cmd_export ;;
    import)  cmd_import ;;
    update)
        log "Updating bear.sh from latest release..."
        tmp=$(mktemp)
        if curl -fsSL "https://raw.githubusercontent.com/sandip-mane/bear-github-sync/main/bear.sh" -o "$tmp"; then
            mv "$tmp" "$SCRIPT_DIR/bear.sh"
            chmod +x "$SCRIPT_DIR/bear.sh"
            log "Updated successfully."
        else
            rm -f "$tmp"
            err "Failed to download update."
        fi
        ;;
    help|*)
        echo "Usage: bear.sh <command>"
        echo ""
        echo "Commands:"
        echo "  export    Export Bear notes to repo and push (Bear → GitHub)"
        echo "  import    Pull from remote and import into Bear (GitHub → Bear)"
        echo "  update    Update bear.sh to the latest version"
        exit 0
        ;;
esac
