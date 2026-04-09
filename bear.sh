#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Configuration (override via .bear-sync.conf if needed) ---

BEAR_DB="${BEAR_DB:-$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite}"
BEAR_FILES="${BEAR_FILES:-$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/Local Files/Note Images}"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

# Load overrides if config file exists
[[ -f "$SCRIPT_DIR/.bear-sync.conf" ]] && source "$SCRIPT_DIR/.bear-sync.conf"

MANIFEST="$REPO_DIR/.manifest.json"
NOTES_DIR="$REPO_DIR/notes"
ATTACH_DIR="$REPO_DIR/attachments"
DRY_RUN=false

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

file_checksum() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

load_manifest() {
    if [[ -f "$MANIFEST" ]]; then cat "$MANIFEST"; else echo '{"notes":{}}'; fi
}

save_manifest() {
    local tmp
    tmp=$(mktemp "$MANIFEST.XXXXXX")
    echo "$1" | jq '.' > "$tmp" && mv "$tmp" "$MANIFEST" || { rm -f "$tmp"; err "Failed to save manifest"; }
}

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().rstrip('\n'),safe=''))" <<< "$1"
}

bear_is_running() { pgrep -x "Bear" > /dev/null 2>&1; }
log() { echo "[bear-sync] $*"; }
warn() { echo "[bear-sync] WARNING: $*" >&2; }
err() { echo "[bear-sync] ERROR: $*" >&2; exit 1; }

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

    # Clean up orphaned attachments
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
    log "Starting export..."
    [[ -f "$BEAR_DB" ]] || err "Bear database not found at: $BEAR_DB"
    mkdir -p "$NOTES_DIR" "$ATTACH_DIR"

    local manifest
    manifest=$(load_manifest)
    local new_count=0 updated_count=0 deleted_count=0 unchanged_count=0 skipped_count=0

    # Temp files for tracking seen UUIDs and used slugs
    local seen_uuids_file used_slugs_file
    seen_uuids_file=$(mktemp)
    used_slugs_file=$(mktemp)
    trap "rm -f '$seen_uuids_file' '$used_slugs_file'" EXIT

    while IFS=$'\t' read -r uuid title created_ts modified_ts encrypted tags; do
        echo "$uuid" >> "$seen_uuids_file"

        if [[ "$encrypted" == "1" ]]; then
            warn "Skipping encrypted note: $title"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        local created modified
        created=$(coredata_to_iso "$created_ts")
        modified=$(coredata_to_iso "$modified_ts")

        local manifest_modified
        manifest_modified=$(echo "$manifest" | jq -r --arg u "$uuid" '.notes[$u].modified // ""')

        if [[ "$manifest_modified" == "$modified" ]]; then
            unchanged_count=$((unchanged_count + 1))
            echo "$manifest" | jq -r --arg u "$uuid" '.notes[$u].filename // ""' | sed 's/\.md$//' >> "$used_slugs_file"
            continue
        fi

        local slug
        slug=$(slugify "$title")
        [[ -z "$slug" ]] && slug="untitled"

        # Collision detection
        while grep -qx "$slug" "$used_slugs_file" 2>/dev/null; do
            local i=2 base_slug="$slug"
            while grep -qx "${base_slug}-${i}" "$used_slugs_file" 2>/dev/null; do i=$((i + 1)); done
            slug="${base_slug}-${i}"
        done
        echo "$slug" >> "$used_slugs_file"

        local filename="${slug}.md"

        # Handle title renames
        local old_filename
        old_filename=$(echo "$manifest" | jq -r --arg u "$uuid" '.notes[$u].filename // ""')
        if [[ -n "$old_filename" && "$old_filename" != "$filename" && "$DRY_RUN" == "false" ]]; then
            rm -f "$NOTES_DIR/$old_filename"
            rm -rf "$ATTACH_DIR/${old_filename%.md}"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ -z "$manifest_modified" ]]; then
                log "[DRY RUN] Would create: $filename"
                new_count=$((new_count + 1))
            else
                log "[DRY RUN] Would update: $filename"
                updated_count=$((updated_count + 1))
            fi
            continue
        fi

        local text body frontmatter
        text=$(query_note_text "$uuid")
        body=$(strip_bear_title_line "$text")
        body=$(strip_tag_markers "$body")
        body=$(rewrite_images_for_export "$body" "$slug")
        frontmatter=$(build_frontmatter "$uuid" "$title" "$tags" "$created" "$modified")

        printf '%s\n%s\n' "$frontmatter" "$body" > "$NOTES_DIR/$filename"

        export_attachments "$uuid" "$slug"

        local checksum attach_json="[]"
        checksum=$(file_checksum "$NOTES_DIR/$filename")
        [[ -d "$ATTACH_DIR/$slug" ]] && attach_json=$(ls "$ATTACH_DIR/$slug" 2>/dev/null | jq -R . | jq -sc .)

        manifest=$(echo "$manifest" | jq \
            --arg u "$uuid" --arg f "$filename" --arg c "$checksum" \
            --arg m "$modified" --argjson a "$attach_json" \
            '.notes[$u] = {filename: $f, checksum: $c, modified: $m, attachments: $a}')

        if [[ -z "$manifest_modified" ]]; then
            new_count=$((new_count + 1))
        else
            updated_count=$((updated_count + 1))
        fi
    done < <(query_bear_notes)

    # Deletion sync
    if [[ ! -s "$seen_uuids_file" ]]; then
        warn "No notes seen — skipping deletion sync"
    else
        for muuid in $(echo "$manifest" | jq -r '.notes | keys[]'); do
            grep -qx "$muuid" "$seen_uuids_file" && continue
            local del_filename
            del_filename=$(echo "$manifest" | jq -r --arg u "$muuid" '.notes[$u].filename')
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY RUN] Would delete: $del_filename"
            else
                rm -f "$NOTES_DIR/$del_filename"
                rm -rf "$ATTACH_DIR/${del_filename%.md}"
                manifest=$(echo "$manifest" | jq --arg u "$muuid" 'del(.notes[$u])')
                log "Deleted: $del_filename"
            fi
            deleted_count=$((deleted_count + 1))
        done
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
        save_manifest "$manifest"
        cd "$REPO_DIR"
        # Only stage notes/, attachments/, and manifest — never use 'git add -A'
        # which would delete repo files not present on this machine
        git add notes/ attachments/ .manifest.json
        if ! git diff --cached --quiet; then
            git commit -m "bear export: $new_count new, $updated_count updated, $deleted_count deleted"
            git remote get-url origin > /dev/null 2>&1 && git push && log "Pushed to origin"
        else
            log "No changes to commit"
        fi
    fi

    log "Export complete: $new_count new, $updated_count updated, $deleted_count deleted, $unchanged_count unchanged, $skipped_count skipped"
}

cmd_import() {
    log "Starting import..."
    bear_is_running || err "Bear is not running. Please open Bear and try again."

    cd "$REPO_DIR"
    git remote get-url origin > /dev/null 2>&1 && { git pull --rebase 2>/dev/null || git pull; }

    local manifest
    manifest=$(load_manifest)
    local new_count=0 updated_count=0 deleted_count=0 unchanged_count=0

    local seen_uuids_file
    seen_uuids_file=$(mktemp)
    trap "rm -f '$seen_uuids_file'" EXIT

    for mdfile in "$NOTES_DIR"/*.md; do
        [[ -f "$mdfile" ]] || continue

        local filename slug
        filename=$(basename "$mdfile")
        slug="${filename%.md}"

        # Parse frontmatter once
        local fm
        fm=$(extract_frontmatter "$mdfile")
        local uuid title tags
        uuid=$(parse_frontmatter_field "$fm" "uuid")
        title=$(parse_frontmatter_field "$fm" "title")
        tags=$(parse_frontmatter_tags "$fm")

        [[ -z "$uuid" ]] && warn "No UUID in frontmatter for $filename, treating as new note"

        local checksum manifest_checksum=""
        checksum=$(file_checksum "$mdfile")
        if [[ -n "$uuid" ]]; then
            manifest_checksum=$(echo "$manifest" | jq -r --arg u "$uuid" '.notes[$u].checksum // ""')
            echo "$uuid" >> "$seen_uuids_file"
        fi

        if [[ -n "$manifest_checksum" && "$checksum" == "$manifest_checksum" ]]; then
            unchanged_count=$((unchanged_count + 1))
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ -z "$manifest_checksum" ]]; then
                log "[DRY RUN] Would create in Bear: $title"
                new_count=$((new_count + 1))
            else
                log "[DRY RUN] Would update in Bear: $title"
                updated_count=$((updated_count + 1))
            fi
            continue
        fi

        local body
        body=$(strip_frontmatter "$mdfile")
        body=$(rewrite_images_for_import "$body" "$slug")

        # Trash old note if updating
        if [[ -n "$uuid" && -n "$manifest_checksum" ]]; then
            log "Trashing old version: $title"
            open "bear://x-callback-url/trash?id=${uuid}" 2>/dev/null
            sleep 1
        fi

        # Create note via x-callback-url
        local encoded_title encoded_tags encoded_body
        encoded_title=$(urlencode "$title")
        encoded_tags=$(urlencode "$tags")
        encoded_body=$(urlencode "$body")
        open "bear://x-callback-url/create?title=${encoded_title}&text=${encoded_body}&tags=${encoded_tags}" 2>/dev/null
        sleep 1.5
        log "Imported: $title"

        if [[ -n "$uuid" && -z "$manifest_checksum" ]]; then
            manifest=$(echo "$manifest" | jq \
                --arg u "$uuid" --arg f "$filename" --arg c "$checksum" \
                '.notes[$u] = {filename: $f, checksum: $c}')
            new_count=$((new_count + 1))
        elif [[ -n "$uuid" && -n "$manifest_checksum" ]]; then
            manifest=$(echo "$manifest" | jq --arg u "$uuid" 'del(.notes[$u])')
            updated_count=$((updated_count + 1))
        else
            new_count=$((new_count + 1))
        fi
    done

    # Deletion sync
    if [[ ! -s "$seen_uuids_file" ]]; then
        warn "No notes seen — skipping deletion sync"
    else
        for muuid in $(echo "$manifest" | jq -r '.notes | keys[]'); do
            grep -qx "$muuid" "$seen_uuids_file" && continue
            local del_title
            del_title=$(echo "$manifest" | jq -r --arg u "$muuid" '.notes[$u].filename // "unknown"')
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY RUN] Would trash in Bear: $del_title (UUID: $muuid)"
            else
                open "bear://x-callback-url/trash?id=${muuid}" 2>/dev/null
                sleep 1
                manifest=$(echo "$manifest" | jq --arg u "$muuid" 'del(.notes[$u])')
                log "Trashed in Bear: $del_title"
            fi
            deleted_count=$((deleted_count + 1))
        done
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
        save_manifest "$manifest"
        cd "$REPO_DIR"
        git add .manifest.json
        if ! git diff --cached --quiet; then
            git commit -m "bear import: updated manifest"
            git remote get-url origin > /dev/null 2>&1 && git push
        fi
    fi

    log "Import complete: $new_count new, $updated_count updated, $deleted_count deleted, $unchanged_count unchanged"
}

# --- Argument Parsing ---

COMMAND="${1:-help}"
shift || true
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) warn "Unknown argument: $arg" ;;
    esac
done

case "$COMMAND" in
    export)  cmd_export ;;
    import)  cmd_import ;;
    sync)    cmd_import && cmd_export ;;
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
        echo "Usage: bear.sh <command> [--dry-run]"
        echo ""
        echo "Commands:"
        echo "  sync      Full sync (import remote changes, then export local)"
        echo "  export    Export Bear notes to repo (Bear → GitHub)"
        echo "  import    Import notes from repo to Bear (GitHub → Bear)"
        echo "  update    Update bear.sh to the latest version"
        echo ""
        echo "Options:"
        echo "  --dry-run  Show what would change without making changes"
        exit 0
        ;;
esac
