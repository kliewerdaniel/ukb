---
name: knowledge-base
description: "Universal knowledge base system for any domain. Builds searchable, embeddable, web-UI-equipped knowledge bases from markdown documents and an .sspec configuration file. Handles chunking, semantic embeddings (Ollama), topic indexing, cross-references, and provides CLI, MCP, and web interfaces. Use this skill when the user wants to build a knowledge base, search documents, query a corpus, set up document retrieval, create a RAG system, or make documents searchable. Also use when the user mentions kb-tools, knowledge base, doc search, semantic search, or wants to build a local-first document retrieval system."
---

# Knowledge Base Skill

Universal spec-driven knowledge base system. Builds complete retrieval pipelines from markdown documents.

## What This Skill Does

This skill provides a complete knowledge base pipeline:

1. **Ingestion** — Markdown documents are organized, chunked, and indexed
2. **Embedding** — Vector embeddings via Ollama nomic-embed-text for semantic search
3. **Indexing** — Topic index, cross-references, and document catalog
4. **Retrieval** — CLI, web UI, and MCP server for querying

**Core Philosophy:** *Define once, search everywhere.*
- `.sspec` file defines the knowledge base configuration
- `start.sh` builds everything from that definition
- All processing is local — no cloud APIs
- Same input produces deterministic output

## When to Use This Skill

Use this skill when:

- **Building a knowledge base** — from markdown documents on any topic
- **Searching documents** — keyword, semantic, or hybrid search
- **Querying a corpus** — research questions with source citations
- **Setting up RAG** — document retrieval for LLM context
- **Creating document search** — for technical docs, legal texts, research papers
- **The user mentions** knowledge base, doc search, semantic search, kb-tools, document retrieval, RAG, or wants to make documents searchable

**Do NOT use this skill when:** the user wants a simple file grep, database queries, or structured data search (not markdown).

## Prerequisites

Before running any commands, verify:

1. **Python 3.8+ installed** — `python3 --version`
2. **Ollama running** — `ollama serve` (for embeddings and LLM)
3. **nomic-embed-text model** — `ollama pull nomic-embed-text`
4. **flask installed** — `pip install flask`
5. **numpy installed** — `pip install numpy`

If Ollama isn't installed:
```bash
brew install ollama
ollama serve  # Start in background
ollama pull nomic-embed-text
```

## Project Structure

```
project/
├── sources/               # Input markdown files
├── start.sh               # Build script
├── ex.sspec               # Example spec template
├── my-kb.sspec            # Your knowledge base spec
├── kbmd/                  # Organized sources (auto-generated)
├── kb-config.json         # Runtime config
├── kb-topics.json         # Topic definitions
├── kb-index/              # Generated indexes
│   ├── catalog.json
│   ├── chunks/
│   ├── embeddings/
│   ├── topic-index.json
│   ├── cross-references.json
│   └── ...
└── kb-tools/              # Query tools
    ├── engine.py
    ├── server.py
    ├── search.py
    ├── query.py
    └── ...
```

## The .sspec Format

Simple INI-like format with `[sections]` and `key: value` pairs.

### Required Sections

```ini
[kb]
name: My Knowledge Base
description: What this KB contains
version: 1.0.0

[sources]
dir: ./sources            # Path to markdown files (relative to cwd)
```

### Optional Sections

```ini
[categories]
default: chapter          # Chunking: chapter, section, paragraph, file, none

[topics]
topic_name = keyword1, keyword2, keyword3

[references]
pattern_name = regex_with_named_groups

[llm]
system_prompt: >
  You are a research assistant for "{kb_name}".
  Answer questions using provided document excerpts.
  Every claim must cite its source.
embed_model: nomic-embed-text
chat_model:                # Empty = auto-detect

[web]
port: 8080
host: 127.0.0.1

[build]
skip_embeddings: false
max_chunk_tokens: 2000
```

### Multi-line Values

Use `>` for multi-line values ( YAML-style folding):
```ini
[llm]
system_prompt: >
  Line 1
  Line 2
  Line 3
```

Or end with a blank line:
```ini
[llm]
system_prompt: First line.

Second paragraph.
```

## The Build Pipeline

`start.sh` executes these steps:

1. **Parse .sspec** — Extract configuration
2. **Create directories** — `kbmd/`, `kb-index/`, `kb-tools/`
3. **Copy tools** — Python scripts from `kb-tools/`
4. **Import sources** — Copy .md files into `kbmd/<category>/`
5. **Generate manifest** — `manifest.json` from imported files
6. **Generate config** — `kb-config.json` with KB name, paths, prompt
7. **Patch tools** — Replace any hardcoded domain-specific content with your configuration
8. **Build catalog** — `catalog.json` with document metadata
9. **Chunk documents** — Split into ~2000-token pieces
10. **Extract references** — Custom reference patterns from your .sspec (if defined)
11. **Build cross-references** — Document citation graph
12. **Build topic index** — Map topics to document locations
13. **Generate embeddings** — Vector index via Ollama (optional)

## Using the Tools

### CLI Search

```bash
# Keyword search (fast, exact matching)
python3 kb-tools/search.py "error handling"

# Semantic search (conceptual, requires embeddings)
python3 kb-tools/search.py --mode semantic "how to handle failures"

# Auto mode (tries semantic first, falls back to keyword)
python3 kb-tools/search.py --mode auto "deployment process"

# Category-scoped
python3 kb-tools/search.py --mode keyword --category docs "API"

# JSON output
python3 kb-tools/search.py --json "query"
```

### Research Queries

```bash
# Generate a research brief
python3 kb-tools/query.py "What is the architecture of X?"

# Compare two topics
python3 kb-tools/query.py --compare "How do A and B differ?"

# JSON output
python3 kb-tools/query.py --json "topic"
```

### Web UI

```bash
python3 kb-tools/server.py --port 8080
# Open http://localhost:8080
```

API endpoints:
- `POST /api/search` — `{query, mode, max_results}`
- `POST /api/query` — `{question, mode}`
- `POST /api/query-stream` — SSE streaming response
- `GET /api/health` — System status
- `GET /api/documents` — Document catalog
- `GET /api/topics` — Topic index

### MCP Server

```bash
# Stdio transport — add to MCP client config
python3 kb-tools/mcp_server.py
```

Tools:
- `search_knowledge(query, mode, max_results)` — Multi-mode search
- `query_knowledge(question, mode, max_results)` — Search + LLM answer
- `get_sources(doc_id)` — Document metadata + cross-refs
- `list_documents(category)` — Catalog listing

### Rebuild Indexes

```bash
# Full rebuild
python3 kb-tools/build-indexes.py

# Specific index
python3 kb-tools/build-indexes.py --index catalog
python3 kb-tools/build-indexes.py --index chunks
python3 kb-tools/build-indexes.py --index topic
python3 kb-tools/build-indexes.py --index embeddings

# Skip embeddings
python3 kb-tools/build-indexes.py --skip-embeddings
```

## Search Modes

| Mode | How It Works | Best For |
|------|-------------|----------|
| `auto` | Tries semantic, falls back to keyword | General queries |
| `keyword` | Exact text matching (ripgrep or Python) | Specific terms, error messages |
| `semantic` | Vector similarity via embeddings | Conceptual queries, fuzzy matching |

## Chunking Strategies

| Strategy | When to Use | Boundary |
|----------|-------------|----------|
| `chapter` | Books, manuals with `## Heading` | `## ` headers |
| `section` | Documents with clear sections | `## ` headers with size limits |
| `paragraph` | Long continuous text | Every 20-30 paragraphs |
| `file` | Small documents (<2000 tokens) | One chunk per file |
| `none` | Very small files | No chunking |

## Topic Indexing

Topics are defined in the .sspec file with seed keywords:

```ini
[topics]
deployment = deploy, deployment, server, infrastructure
api = api, endpoint, request, response, rest
```

The indexer scans each chunk for these keywords and maps chunks to topics. Use this to quickly find all documents related to a concept.

## Cross-Reference Extraction

Define regex patterns to extract citations between documents:

```ini
[references]
issue = #(?P<id>\d+)
section = Section\s+(?P<id>[\d.]+)
citation = \[(?P<id>[A-Z]+\d{4})\]
```

The `(?P<id>...)` named group captures the referenced ID. This builds a citation graph between documents.

## Example: Building a KB for a Software Project

```bash
# 1. Create your spec
cat > my-project.sspec << 'EOF'
[kb]
name: My Project Docs
description: Technical documentation for MyProject.

[sources]
dir: ./docs

[categories]
default: chapter

[topics]
api = api, endpoint, rest, graphql
deploy = deploy, docker, kubernetes, ci/cd
config = config, settings, environment, env

[llm]
system_prompt: >
  You are a documentation assistant for MyProject.
  Answer questions using the provided docs.
  Cite document titles and sections.

[web]
port: 8080
EOF

# 2. Add your docs
mkdir -p docs
cp your-docs/*.md docs/

# 3. Build
./start.sh my-project.sspec

# 4. Use
python3 kb-tools/search.py "how to deploy"
python3 kb-tools/server.py
```

## Example: Building a KB for Research Papers

```bash
cat > papers.sspec << 'EOF'
[kb]
name: Research Paper Collection
description: Academic papers on machine learning.

[sources]
dir: ./papers

[categories]
default: section

[topics]
transformers = transformer, attention, self-attention, bert, gpt
reinforcement = reinforcement learning, reward, policy, q-learning
generative = generative, gan, diffusion, vae

[references]
citation = \[(?P<id>[A-Z]+\d{4})\]
arxiv = arXiv:(?P<id>\d{4}\.\d{4,5})

[llm]
system_prompt: >
  You are a research assistant for a paper collection.
  Answer questions citing paper titles and authors.
  Distinguish between the papers' claims and your synthesis.
EOF
```

## Troubleshooting

**Ollama not connecting:**
```bash
ollama serve  # Start Ollama
curl http://localhost:11434/api/tags  # Verify
```

**No chunks generated:**
- Check that sources contain `.md` files
- Verify the `dir:` path in your .sspec is correct
- Look for errors in `start.sh` output

**Embeddings fail:**
```bash
ollama pull nomic-embed-text
# Then rebuild: ./start.sh my.kb.sspec --rebuild
```

**Web UI won't start:**
```bash
pip install flask
# Check if port is in use: lsof -i :8080
```

## Constraints

1. Sources must be markdown (`.md`) files
2. Local-only — no cloud APIs
3. All indexes are derived from sources — regenerate anytime
4. `kbmd/` is the source of truth — never edit directly
5. Same input produces deterministic output
