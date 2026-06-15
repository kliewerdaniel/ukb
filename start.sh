#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# start.sh — Universal Knowledge Base Setup Script
# ═══════════════════════════════════════════════════════════════════════════════
# Reads an .sspec file and builds a complete, searchable knowledge base:
#   - Directory structure
#   - Document chunks
#   - Semantic embeddings (via Ollama)
#   - Web UI with streaming chat
#   - MCP server for agent integration
#
# Usage:
#   ./start.sh <spec-file.sspec>
#   ./start.sh ex.sspec              # Build from example spec
#   ./start.sh my-kb.sspec --serve   # Build and start web UI
#   ./start.sh my-kb.sspec --rebuild # Rebuild indexes only
#
# Requirements:
#   - Python 3.8+
#   - Ollama running (for embeddings): ollama serve
#   - nomic-embed-text model: ollama pull nomic-embed-text
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[KB]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ─── Locate tools directory ──────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_SOURCE="$SCRIPT_DIR/kb-tools"

# ─── Argument Parsing ────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <spec-file.sspec> [options]

Options:
  --serve         Start the web UI after building
  --rebuild       Rebuild indexes only (skip source copy)
  --port PORT     Web UI port (default: 8080)
  --no-embed      Skip embedding generation
  --help          Show this help

Examples:
  ./start.sh ex.sspec
  ./start.sh ex.sspec --serve
  ./start.sh my-kb.sspec --serve --port 3000
  ./start.sh my-kb.sspec --rebuild
EOF
    exit 0
}

SPEC_FILE=""
DO_SERVE=false
REBUILD=false
PORT=8080
SKIP_EMBED=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --serve)     DO_SERVE=true; shift ;;
        --rebuild)   REBUILD=true; shift ;;
        --port)      PORT="$2"; shift 2 ;;
        --no-embed)  SKIP_EMBED=true; shift ;;
        --help|-h)   usage ;;
        -*)          error "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$SPEC_FILE" ]]; then
                SPEC_FILE="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$SPEC_FILE" ]]; then
    error "No spec file provided."
    echo ""
    usage
fi

if [[ ! -f "$SPEC_FILE" ]]; then
    error "Spec file not found: $SPEC_FILE"
    exit 1
fi

# ─── Parse .sspec File ───────────────────────────────────────────────────────
# Simple INI-like parser. Supports [sections] and key = value pairs.
# Multi-line values: continue until blank line or next section header.

parse_sspec() {
    local file="$1"
    local current_section=""
    local current_key=""
    local in_multiline=false
    local multiline_buffer=""

    declare -gA SSPEC_SCALARS=()
    declare -gA SSPEC_MULTILINES=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading/trailing whitespace AND carriage returns
        line="$(echo "$line" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && {
            if $in_multiline && [[ -n "$current_key" ]]; then
                SSPEC_MULTILINES["${current_section}.${current_key}"]="$multiline_buffer"
                in_multiline=false
                multiline_buffer=""
                current_key=""
            fi
            continue
        }

        # Section header
        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            if $in_multiline && [[ -n "$current_key" ]]; then
                SSPEC_MULTILINES["${current_section}.${current_key}"]="$multiline_buffer"
                in_multiline=false
                multiline_buffer=""
                current_key=""
            fi
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Key = value (supports = or : separator)
        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*[=:][[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Check for multi-line value (ends with >)
            if [[ "$value" == ">" ]]; then
                in_multiline=true
                current_key="$key"
                multiline_buffer=""
            else
                # Strip quotes
                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
                SSPEC_SCALARS["${current_section}.${key}"]="$value"
                current_key=""
            fi
            continue
        fi

        # Continuation of multi-line value
        if $in_multiline; then
            if [[ -n "$multiline_buffer" ]]; then
                multiline_buffer+=$'\n'"$line"
            else
                multiline_buffer="$line"
            fi
        fi

    done < "$file"

    # Flush last multi-line
    if $in_multiline && [[ -n "$current_key" ]]; then
        SSPEC_MULTILINES["${current_section}.${current_key}"]="$multiline_buffer"
    fi
}

# Helper: get scalar value with default
sspec_get() {
    local section="$1"
    local key="$2"
    local default="${3:-}"
    echo "${SSPEC_SCALARS["${section}.${key}"]:-$default}"
}

# Helper: get multi-line value
sspec_get_ml() {
    local section="$1"
    local key="$2"
    local default="${3:-}"
    echo "${SSPEC_MULTILINES["${section}.${key}"]:-$default}"
}

# ─── Parse the spec ──────────────────────────────────────────────────────────

step "Parsing spec file"
parse_sspec "$SPEC_FILE"

KB_NAME="$(sspec_get "kb" "name" "Knowledge Base")"
KB_DESC="$(sspec_get "kb" "description" "")"
KB_VERSION="$(sspec_get "kb" "version" "1.0.0")"
SOURCE_DIR="$(sspec_get "sources" "dir" "./sources")"
SOURCE_GIT="$(sspec_get "sources" "git" "")"
DEFAULT_CHUNK_STRATEGY="$(sspec_get "categories" "default" "chapter")"
EMBED_MODEL="$(sspec_get "llm" "embed_model" "nomic-embed-text")"
CHAT_MODEL="$(sspec_get "llm" "chat_model" "")"
WEB_PORT="$(sspec_get "web" "port" "$PORT")"
WEB_HOST="$(sspec_get "web" "host" "127.0.0.1")"
SKIP_EMBED_SPEC="$(sspec_get "build" "skip_embeddings" "false")"

[[ "$SKIP_EMBED_SPEC" == "true" ]] && SKIP_EMBED=true

log "KB Name:    $KB_NAME"
log "Source:     ${SOURCE_DIR:-git: $SOURCE_GIT}"
log "Embeddings: $(if $SKIP_EMBED; then echo 'skipped'; else echo "$EMBED_MODEL"; fi)"

# ─── Resolve project directory ───────────────────────────────────────────────

KB_DIR="${SOURCE_DIR%/}"
KB_DIR="${KB_DIR#./}"
KB_DIR="$(dirname "$KB_DIR")"
KB_DIR="$(cd "$KB_DIR" 2>/dev/null && pwd)" || KB_DIR="$(pwd)"
KBMD_DIR="$KB_DIR/kbmd"
KB_INDEX="$KB_DIR/kb-index"
KB_TOOLS="$KB_DIR/kb-tools"
KB_CONFIG="$KB_DIR/kb-config.json"
MANIFEST="$KBMD_DIR/manifest.json"

# ─── Setup Directories ───────────────────────────────────────────────────────

step "Setting up directories"

if ! $REBUILD; then
    mkdir -p "$KBMD_DIR"
    mkdir -p "$KB_INDEX"
    mkdir -p "$KB_TOOLS/templates"

    # ─── Copy Python Tools ───────────────────────────────────────────────

    log "Copying tools..."
    if [[ -d "$TOOLS_SOURCE" ]]; then
        for tool in "$TOOLS_SOURCE"/*.py; do
            [[ -f "$tool" ]] && cp "$tool" "$KB_TOOLS/"
        done
        if [[ -d "$TOOLS_SOURCE/templates" ]]; then
            cp -r "$TOOLS_SOURCE/templates/"* "$KB_TOOLS/templates/" 2>/dev/null || true
        fi
    else
        warn "Tools source not found at $TOOLS_SOURCE"
        warn "You may need to copy kb-tools/ manually."
    fi

    # ─── Copy Source Documents ───────────────────────────────────────────

    step "Importing sources"

    # Git source
    if [[ -n "$SOURCE_GIT" ]]; then
        local_repo="$KB_DIR/.sources"
        if [[ -d "$local_repo" ]]; then
            log "Updating git source..."
            git -C "$local_repo" pull --quiet 2>/dev/null || true
        else
            log "Cloning git source..."
            git clone --quiet "$SOURCE_GIT" "$local_repo"
        fi
        SOURCE_DIR="$local_repo"
    fi

    # Copy markdown files
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]]; then
        find "$SOURCE_DIR" -name "*.md" -type f | while read -r src; do
            # Preserve relative path structure
            rel="${src#"$SOURCE_DIR"/}"
            dir_part="$(dirname "$rel")"

            # Determine category from directory
            category="$(echo "$dir_part" | cut -d'/' -f1)"
            if [[ "$category" == "." ]]; then
                category="general"
            fi

            mkdir -p "$KBMD_DIR/$category"
            cp "$src" "$KBMD_DIR/$category/"
            log "  Imported: $category/$(basename "$src")"
        done
    else
        error "Source directory not found: $SOURCE_DIR"
        error "Create the directory and add .md files, or update your .sspec sources."
        exit 1
    fi

    # ─── Handle files= directive ─────────────────────────────────────────

    # (files= lines are parsed but handled via the dir= fallback above)
    # If dir= doesn't exist but files= is specified, create from files
    if [[ ! -d "$SOURCE_DIR" ]] && [[ -n "$(sspec_get "sources" "files" "")" ]]; then
        mkdir -p "$KBMD_DIR/general"
        # Read files from spec (this is a simplified approach)
        warn "files= directive requires dir= to exist. Place files in $SOURCE_DIR."
    fi

    # ─── Count imported files ────────────────────────────────────────────

    FILE_COUNT=$(find "$KBMD_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
    TOTAL_SIZE=$(du -sh "$KBMD_DIR" 2>/dev/null | cut -f1)
    log "Imported $FILE_COUNT documents ($TOTAL_SIZE)"
else
    log "Rebuild mode — skipping source import"
    FILE_COUNT=$(find "$KBMD_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "Existing documents: $FILE_COUNT"
fi

# ─── Build Topic Definitions ─────────────────────────────────────────────────

step "Generating topic definitions"

TOPICS_JSON="$KB_DIR/kb-topics.json"
{
    echo "{"
    first=true
    # Read [topics] section from spec
    in_topics=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$line" == \#* || -z "$line" ]] && continue

        if [[ "$line" == "[topics]" ]]; then
            in_topics=true
            continue
        fi
        if [[ "$line" =~ ^\[ ]]; then
            $in_topics && break
            in_topics=false
            continue
        fi

        if $in_topics && [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*[=:][[:space:]]*(.+)$ ]]; then
            topic_name="${BASH_REMATCH[1]}"
            keywords="${BASH_REMATCH[2]}"
            # Convert comma-separated to JSON array
            kw_json=$(echo "$keywords" | sed 's/,\s*/", "/g' | sed 's/^/["/' | sed 's/$/"]/')
            $first || echo ","
            echo "  \"$topic_name\": $kw_json"
            first=false
        fi
    done < "$SPEC_FILE"
    echo ""
    echo "}"
} > "$TOPICS_JSON"

log "Topics written to $TOPICS_JSON"

# ─── Build Reference Patterns ────────────────────────────────────────────────

step "Generating reference patterns"

REFS_JSON="$KB_INDEX/ref-patterns.json"
{
    echo "{"
    first=true
    in_refs=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$line" == \#* || -z "$line" ]] && continue

        if [[ "$line" == "[references]" ]]; then
            in_refs=true
            continue
        fi
        if [[ "$line" =~ ^\[ ]]; then
            $in_refs && break
            in_refs=false
            continue
        fi

        if $in_refs && [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*[=:][[:space:]]*(.+)$ ]]; then
            ref_name="${BASH_REMATCH[1]}"
            ref_pattern="${BASH_REMATCH[2]}"
            $first || echo ","
            printf '  "%s": "%s"' "$ref_name" "$(echo "$ref_pattern" | sed 's/"/\\"/g')"
            first=false
        fi
    done < "$SPEC_FILE"
    echo ""
    echo "}"
} > "$KB_INDEX/ref-patterns.json" 2>/dev/null || true

log "Reference patterns written"

# ─── Generate manifest.json ──────────────────────────────────────────────────

step "Generating manifest"

python3 - "$KBMD_DIR" "$MANIFEST" "$KB_NAME" "$KB_DESC" <<'PYMANIFEST'
import json, os, sys
from pathlib import Path
from datetime import datetime, timezone

kbmd_dir = Path(sys.argv[1])
out_path = Path(sys.argv[2])
kb_name = sys.argv[3]
kb_desc = sys.argv[4]

documents = []
categories = {}

for md_file in sorted(kbmd_dir.rglob("*.md")):
    rel = str(md_file.relative_to(kbmd_dir.parent))
    # Category is the first directory component
    parts = md_file.relative_to(kbmd_dir).parts
    category = parts[0] if len(parts) > 1 else "general"

    size = md_file.stat().st_size
    title = md_file.stem.replace("_", " ").replace("-", " ").title()

    # Try to extract title from first heading
    try:
        content = md_file.read_text(encoding="utf-8", errors="replace")[:2000]
        import re
        m = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
        if m:
            title = m.group(1).strip()
        m = re.search(r'^---\s*\n.*?title:\s*"(.+?)"', content, re.DOTALL)
        if m:
            title = m.group(1)
    except Exception:
        pass

    documents.append({
        "path": rel,
        "title": title,
        "category": category,
        "subcategory": None,
        "size_bytes": size,
    })

    categories[category] = categories.get(category, 0) + 1

manifest = {
    "name": kb_name,
    "description": kb_desc,
    "generated": datetime.now(timezone.utc).isoformat(),
    "total_documents": len(documents),
    "total_size_bytes": sum(d["size_bytes"] for d in documents),
    "categories": categories,
    "documents": documents,
}

out_path.parent.mkdir(parents=True, exist_ok=True)
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)

print(f"  Manifest: {len(documents)} documents, {len(categories)} categories")
PYMANIFEST

# ─── Generate kb-config.json ─────────────────────────────────────────────────

step "Generating config"

# Build system prompt with KB name
SYSTEM_PROMPT="$(sspec_get_ml "llm" "system_prompt")"
SYSTEM_PROMPT="${SYSTEM_PROMPT//\{kb_name\}/$KB_NAME}"
SYSTEM_PROMPT="${SYSTEM_PROMPT//\{kb_description\}/$KB_DESC}"

cat > "$KB_CONFIG" <<CONFJSON
{
  "name": "$KB_NAME",
  "description": "$KB_DESC",
  "version": "$KB_VERSION",
  "base_dir": "$KB_DIR",
  "kbmd_dir": "$KBMD_DIR",
  "kb_index": "$KB_INDEX",
  "chat_model": "$CHAT_MODEL",
  "embed_model": "$EMBED_MODEL",
  "system_prompt": $(python3 -c "import json; print(json.dumps('''$SYSTEM_PROMPT'''))" 2>/dev/null || echo "\"You are a knowledgeable research assistant. Answer questions using the provided document excerpts. Every claim must cite its source.\""),
  "web_port": $WEB_PORT,
  "web_host": "$WEB_HOST"
}
CONFJSON

log "Config written to $KB_CONFIG"

# ─── Patch Python Tools for Generic Use ──────────────────────────────────────

step "Patching tools for generic use"

# Patch build-topic-index.py to use custom topics
if [[ -f "$KB_TOOLS/build-topic-index.py" && -f "$TOPICS_JSON" ]]; then
    python3 - "$KB_TOOLS/build-topic-index.py" "$TOPICS_JSON" <<'PYPATCH'
import json, sys, re
from pathlib import Path

tool_path = Path(sys.argv[1])
topics_path = Path(sys.argv[2])

# Load custom topics
with open(topics_path) as f:
    custom_topics = json.load(f)

# Read the tool
content = tool_path.read_text()

# Build new TOPIC_SEEDS block
new_seeds = "TOPIC_SEEDS = {\n"
for topic, keywords in custom_topics.items():
    kw_list = ", ".join(f'"{k}"' for k in keywords)
    new_seeds += f'    "{topic}": [{kw_list}],\n'
new_seeds += "}\n"

# Replace using regex: match from "TOPIC_SEEDS = {" through the closing "}"
# This handles nested braces correctly
pattern = r'TOPIC_SEEDS = \{[^}]*(?:\{[^}]*\}[^}]*)*\}'
content_new, count = re.subn(pattern, new_seeds.rstrip(), content, count=1)

if count > 0:
    tool_path.write_text(content_new)
    print(f"  Patched build-topic-index.py with {len(custom_topics)} topics")
else:
    # Fallback: replace from TOPIC_SEEDS line to the next def or class
    lines = content.split('\n')
    new_lines = []
    skip = False
    for line in lines:
        if 'TOPIC_SEEDS = {' in line:
            skip = True
            new_lines.append(new_seeds.rstrip())
            continue
        if skip:
            if line.strip() == '}' or (line.strip().startswith('}') and not line.strip().startswith('} ')):
                skip = False
                continue
            continue
        new_lines.append(line)
    tool_path.write_text('\n'.join(new_lines))
    print(f"  Patched build-topic-index.py with {len(custom_topics)} topics (fallback)")
PYPATCH
fi

# Patch engine.py to use generic system prompt
if [[ -f "$KB_TOOLS/engine.py" ]]; then
    python3 - "$KB_TOOLS/engine.py" "$SYSTEM_PROMPT" <<'PYENGINE'
import sys
from pathlib import Path

tool_path = Path(sys.argv[1])
new_prompt = sys.argv[2]

content = tool_path.read_text()

# Replace SYSTEM_PROMPT
old_start = 'SYSTEM_PROMPT = """'
old_end = '"""'
idx_start = content.find(old_start)
if idx_start >= 0:
    idx_end = content.find(old_end, idx_start + len(old_start))
    if idx_end >= 0:
        idx_end += len(old_end)
        content = content[:idx_start] + f'SYSTEM_PROMPT = """{new_prompt}"""' + content[idx_end:]
        tool_path.write_text(content)
        print("  Patched engine.py system prompt")
    else:
        print("  WARNING: Could not find SYSTEM_PROMPT closing")
else:
    print("  WARNING: Could not find SYSTEM_PROMPT in engine.py")
PYENGINE
fi

# Patch server.py to use KB name
if [[ -f "$KB_TOOLS/server.py" ]]; then
    python3 - "$KB_TOOLS/server.py" "$KB_NAME" <<'PYSERVER'
import sys
from pathlib import Path

tool_path = Path(sys.argv[1])
kb_name = sys.argv[2]

content = tool_path.read_text()
content = content.replace(
    'print(f"\\n  Catholic Knowledge Base — Web UI")',
    f'print(f"\\n  {kb_name} — Web UI")'
)
tool_path.write_text(content)
print(f"  Patched server.py title to: {kb_name}")
PYSERVER
fi

# Patch build-indexes.py test command
if [[ -f "$KB_TOOLS/build-indexes.py" ]]; then
    python3 - "$KB_TOOLS/build-indexes.py" <<'PYINDEX'
import sys
from pathlib import Path

tool_path = Path(sys.argv[1])
content = tool_path.read_text()
content = content.replace(
    'log("Test with: python3 kb-tools/search.py --mode auto \'transubstantiation\'")',
    'log("Test with: python3 kb-tools/search.py --mode auto \'your query\'")'
)
tool_path.write_text(content)
PYINDEX
fi

# ─── Run Build Pipeline ──────────────────────────────────────────────────────

step "Running build pipeline"

cd "$KB_DIR"

# Step 1: Catalog
log "Step 1/5: Building catalog..."
python3 "$KB_TOOLS/build-catalog.py" 2>&1 | sed 's/^/  /'

# Step 2: Chunks
log "Step 2/5: Chunking documents..."
python3 "$KB_TOOLS/build-chunks.py" 2>&1 | sed 's/^/  /'

# Step 3: References
log "Step 3/5: Extracting references..."
python3 "$KB_TOOLS/extract-refs.py" 2>&1 | sed 's/^/  /'

# Step 4: Cross-references + Topic index
log "Step 4/5: Building cross-references and topics..."
python3 "$KB_TOOLS/build-cross-refs.py" 2>&1 | sed 's/^/  /'
python3 "$KB_TOOLS/build-topic-index.py" 2>&1 | sed 's/^/  /'

# Step 5: Embeddings
if ! $SKIP_EMBED; then
    log "Step 5/5: Generating embeddings (this may take a while)..."
    python3 "$KB_TOOLS/build-embeddings.py" 2>&1 | sed 's/^/  /'
else
    log "Step 5/5: Skipping embeddings (--no-embed)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

step "Build Complete!"

DOCS=$(find "$KBMD_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
CHUNKS=$(find "$KB_INDEX/chunks" -name "*.jsonl" -type f 2>/dev/null | xargs cat 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sh "$KB_INDEX" 2>/dev/null | cut -f1)

echo ""
echo -e "  ${GREEN}$KB_NAME${NC}"
echo -e "  Documents: ${BOLD}$DOCS${NC}"
echo -e "  Chunks:    ${BOLD}$CHUNKS${NC}"
echo -e "  Index:     ${BOLD}$SIZE${NC}"
echo ""

echo -e "  ${BOLD}Usage:${NC}"
echo "  cd $KB_DIR"
echo "  python3 kb-tools/search.py \"your query\""
echo "  python3 kb-tools/query.py \"your question\""
echo "  python3 kb-tools/server.py --port $WEB_PORT"
echo ""

# ─── Optionally Start Server ────────────────────────────────────────────────

if $DO_SERVE; then
    step "Starting Web UI"
    echo -e "  ${CYAN}http://$WEB_HOST:$WEB_PORT${NC}"
    echo ""
    python3 "$KB_TOOLS/server.py" --port "$WEB_PORT" --host "$WEB_HOST"
fi
