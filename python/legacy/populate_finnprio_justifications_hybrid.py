"""
FinnPRIO Database Justification Populator (Hybrid Research Version)

Key features:
- HYBRID RESEARCH: Combines web search with local PDF documents
- Local docs loaded from Species/{EPPO_CODE}/ folder
- Falls back to web-only if no local docs found
- Copies entire database (preserves complete structure)
- Appends AI justifications to answers table
- Handles pathway questions for EACH selected pathway
- Clean plain text output (no markdown)
- Question-specific instructions
- Domain exclusions
"""

import os
import asyncio
import hashlib
import sqlite3
import shutil
from pathlib import Path

# Monkey-patch gpt-researcher's PDF loader BEFORE importing GPTResearcher.
# gpt-researcher's default DocumentLoader uses PyMuPDFLoader (native C extension
# via pymupdf/fitz), which crashes the process with a native access violation
# (0xC0000005 on Windows) when it encounters certain malformed PDFs — the crash
# bypasses Python's try/except entirely. PyPDFLoader uses pypdf (pure Python) and
# handles malformed PDFs gracefully. See gpt_researcher/document/document.py:67.
#
# We also:
#   1. Add a progress counter so the user can see PDF loading activity
#   2. Cache the loaded document set per doc_path, so all 18 questions in one
#      assessment reuse the same parsed PDFs instead of re-parsing 18 times.
import time as _time
from langchain_community.document_loaders import PyPDFLoader
import gpt_researcher.document.document as _gpt_doc

_gpt_doc.PyMuPDFLoader = PyPDFLoader

# Progress counter shared across all _load_document calls within a single load()
_load_progress = {"done": 0, "total": 0, "last_print": 0.0}

# Persistent log of files currently being loaded + known-bad files.
# On a native crash (0xC0000005), the last "LOADING:" line in the log
# identifies the culprit PDF. Files listed in _BAD_FILES_PATH are skipped.
_SCRIPT_DIR = Path(__file__).parent
_LOAD_LOG_PATH = _SCRIPT_DIR / ".pdf_load_log.txt"
_BAD_FILES_PATH = _SCRIPT_DIR / ".pdf_bad_files.txt"

def _get_bad_files():
    if not _BAD_FILES_PATH.exists():
        return set()
    return {line.strip() for line in _BAD_FILES_PATH.read_text(encoding="utf-8").splitlines() if line.strip()}

_BAD_FILES = _get_bad_files()

_original_load_document = _gpt_doc.DocumentLoader._load_document

async def _load_document_with_progress(self, file_path, file_extension):
    filename = os.path.basename(file_path)
    # Skip files previously identified as crashing
    if filename in _BAD_FILES or str(file_path) in _BAD_FILES:
        _load_progress["done"] += 1
        print(f"  ⚠️  [{_load_progress['done']}/{_load_progress['total']}] SKIPPED (known-bad): {filename}", flush=True)
        return []
    # Write BEFORE loading — a native crash will freeze this line as the last entry,
    # identifying the culprit. Flush to disk immediately so the OS writes it.
    try:
        with open(_LOAD_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"LOADING: {file_path}\n")
            f.flush()
            os.fsync(f.fileno())
    except Exception:
        pass
    result = await _original_load_document(self, file_path, file_extension)
    _load_progress["done"] += 1
    # Mark completion in log
    try:
        with open(_LOAD_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"  OK: {file_path}\n")
    except Exception:
        pass
    now = _time.time()
    if now - _load_progress["last_print"] > 1.0 or _load_progress["done"] == _load_progress["total"]:
        print(f"  📖 Loaded {_load_progress['done']}/{_load_progress['total']} documents...", flush=True)
        _load_progress["last_print"] = now
    return result

_gpt_doc.DocumentLoader._load_document = _load_document_with_progress

# Cache parsed documents per path so we don't re-parse 1000+ PDFs for every question
_doc_cache = {}
_original_load = _gpt_doc.DocumentLoader.load

async def _cached_load(self):
    cache_key = str(self.path) if not isinstance(self.path, list) else tuple(self.path)
    if cache_key in _doc_cache:
        print(f"  💾 Reusing cached documents ({len(_doc_cache[cache_key])} pages)", flush=True)
        return _doc_cache[cache_key]

    # Count total files so the progress counter has a denominator
    total = 0
    if isinstance(self.path, list):
        total = sum(1 for p in self.path if os.path.isfile(p))
    else:
        for _root, _dirs, _files in os.walk(self.path):
            total += len(_files)
    _load_progress["done"] = 0
    _load_progress["total"] = total
    _load_progress["last_print"] = 0.0
    # Reset the per-file load log so the last "LOADING:" line always identifies
    # the crashing file from the most recent run.
    try:
        _LOAD_LOG_PATH.write_text(f"# PDF load log for {self.path}\n", encoding="utf-8")
    except Exception:
        pass
    print(f"  📚 Parsing {total} local documents (this happens once per species)...", flush=True)
    if _BAD_FILES:
        print(f"  ⚠️  {len(_BAD_FILES)} known-bad file(s) will be skipped (see {_BAD_FILES_PATH.name})", flush=True)
    t0 = _time.time()
    result = await _original_load(self)
    print(f"  ✅ Parsed {total} documents in {_time.time() - t0:.1f}s ({len(result)} pages extracted)", flush=True)
    _doc_cache[cache_key] = result
    return result

_gpt_doc.DocumentLoader.load = _cached_load


# ---------------------------------------------------------------------------
# FAISS vector store cache for local-doc similarity search.
#
# Problem: in hybrid mode, every sub-query calls
# ContextManager.get_similar_content_by_query(query, pages) with the full
# local corpus, which feeds it through ContextCompressor → EmbeddingsFilter
# and re-embeds every chunk on every call. With ~11000 pages and ~3-5
# sub-queries × 18 questions per species, that's easily 50M+ embedding tokens
# per species — well over the 5M TPM limit on text-embedding-3-small.
#
# Fix: patch get_similar_content_by_query so that substantial corpora (≥50
# pages, i.e. local docs, not small web-scrape batches) are embedded ONCE
# into a FAISS index and cached per species. Subsequent sub-queries hit the
# cache and only pay for embedding the query string (~a few tokens each).
# The cache is cleared in clear_doc_cache() between species.
# ---------------------------------------------------------------------------
_faiss_cache = {}  # key: (doc_path, src_fingerprint); value: FAISS vector store
_faiss_stats = {"hits": 0, "misses": 0}
# Lazy-created in the running event loop so we don't bind to the wrong loop.
_faiss_build_lock = None

# Only corpora at or above this page count get cached; smaller lists are
# web-scrape results that change per sub-query and don't benefit from caching.
_FAISS_CACHE_MIN_PAGES = 50

# How many times the embedding provider retries a single batch. OpenAI's
# default max_retries=2 exhausts quickly while we wait out 5M-TPM throttling
# on large corpora — bump generously, overridable per-run.
_EMBED_MAX_RETRIES = int(os.environ.get("OPENAI_EMBED_MAX_RETRIES", "10"))


def _pages_fingerprint(pages):
    """Species-unique fingerprint derived from the source URLs/paths of the
    corpus. Guarantees two species with the same page count never collide,
    so correctness no longer depends on clear_doc_cache() being called
    between species — that remains the canonical way to bound memory, but
    is no longer load-bearing for result accuracy."""
    src = "|".join(sorted((p.get("url") or "") for p in pages))
    return hashlib.md5(src.encode("utf-8")).hexdigest()


async def _faiss_similarity_search(vs, researcher, query):
    """Top-k similarity search that restores the SIMILARITY_THRESHOLD filter
    the original EmbeddingsFilter applied. FAISS with normalized OpenAI
    embeddings returns relevance scores in [0, 1] — identical semantics to
    the original cosine-based filter."""
    threshold = float(os.environ.get("SIMILARITY_THRESHOLD", 0.42))
    scored = await vs.asimilarity_search_with_relevance_scores(query, k=20)
    results = [doc for doc, score in scored if score >= threshold][:10]
    return researcher.prompt_family.pretty_print_docs(results, 10)


async def _get_similar_cached(self, query, pages):
    from langchain_community.vectorstores import FAISS
    from langchain_text_splitters import RecursiveCharacterTextSplitter
    from langchain_core.documents import Document as _LCDocument
    from gpt_researcher.utils.costs import estimate_embedding_cost
    from gpt_researcher.memory.embeddings import OPENAI_EMBEDDING_MODEL

    global _faiss_build_lock

    if not pages:
        return ""

    # Small page lists (web-scrape results) — fall through to original path;
    # caching them has no benefit and they change per sub-query.
    if len(pages) < _FAISS_CACHE_MIN_PAGES:
        return await _original_get_similar(self, query, pages)

    try:
        doc_path = str(getattr(self.researcher.cfg, "doc_path", "") or "")
    except Exception:
        doc_path = ""
    key = (doc_path, _pages_fingerprint(pages))

    # Cache hit — no lock needed for reads.
    if key in _faiss_cache:
        _faiss_stats["hits"] += 1
        return await _faiss_similarity_search(_faiss_cache[key], self.researcher, query)

    # Cache miss. Serialize the build so concurrent sub-queries don't all
    # stampede the embedding API in parallel (that's what caused the 6-way
    # TPM overflow we saw in the logs).
    if _faiss_build_lock is None:
        _faiss_build_lock = asyncio.Lock()

    async with _faiss_build_lock:
        # Re-check inside the lock: another coroutine may have built it while
        # we were waiting.
        if key in _faiss_cache:
            _faiss_stats["hits"] += 1
            return await _faiss_similarity_search(_faiss_cache[key], self.researcher, query)

        _faiss_stats["misses"] += 1
        print(f"  🧠 Building FAISS index for {len(pages)} local docs (one-time per species)...", flush=True)

        splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=100)
        lc_docs = []
        for p in pages:
            raw = p.get("raw_content") or ""
            if not raw.strip():
                continue
            lc_docs.append(_LCDocument(page_content=raw, metadata={"source": p.get("url", "")}))
        chunks = splitter.split_documents(lc_docs)
        print(f"  📊 Split into {len(chunks)} chunks; embedding now (this will take a few minutes — TPM limit throttles it)...", flush=True)

        embeddings = self.researcher.memory.get_embeddings()
        try:
            if hasattr(embeddings, "max_retries"):
                embeddings.max_retries = _EMBED_MAX_RETRIES
        except Exception:
            pass

        t0 = _time.time()
        try:
            vs = await asyncio.to_thread(FAISS.from_documents, chunks, embeddings)
        except Exception as e:
            # Build failed (OOM, embedding provider outage, 429 after all
            # retries). Fall back to the original EmbeddingsFilter path so
            # this sub-query still returns a result instead of cascading the
            # failure into every remaining question for the species.
            print(f"  ⚠️  FAISS build failed ({e}); falling back to original EmbeddingsFilter path for this query", flush=True)
            return await _original_get_similar(self, query, pages)

        _faiss_cache[key] = vs
        try:
            self.researcher.add_costs(estimate_embedding_cost(model=OPENAI_EMBEDDING_MODEL, docs=pages))
        except Exception:
            pass
        print(f"  ✅ FAISS index built in {_time.time() - t0:.1f}s — all remaining sub-queries will reuse it", flush=True)

    return await _faiss_similarity_search(vs, self.researcher, query)

from gpt_researcher.skills.context_manager import ContextManager as _CM
_original_get_similar = _CM.get_similar_content_by_query
_CM.get_similar_content_by_query = _get_similar_cached


def clear_doc_cache():
    """Clear the document + FAISS vector caches. Call between assessments/species."""
    global _faiss_build_lock
    total = _faiss_stats["hits"] + _faiss_stats["misses"]
    if total:
        print(f"  📈 FAISS cache: {_faiss_stats['hits']} hits / {_faiss_stats['misses']} misses", flush=True)
    _doc_cache.clear()
    _faiss_cache.clear()
    _faiss_stats["hits"] = 0
    _faiss_stats["misses"] = 0
    _faiss_build_lock = None

from gpt_researcher import GPTResearcher
from gpt_researcher.utils.enum import Tone
from datetime import datetime
from typing import Dict, List, Tuple, Optional
import re

# Import instructions loader (auto-generates JSON from Rmd if needed)
from instructions_loader import build_justification_prompt

# =============================================================================
# CONFIGURATION
# =============================================================================

#  IMPORTANT: READ BEFORE RUNNING
#  THIS SCRIPT CREATES A NEW COPY OF YOUR DATABASE EACH TIME IT RUNS!
#  Using original database again will lose all AI work!

# Skip assessments that already have a justification (avoids overwriting existing work)
SKIP_EXISTING_JUSTIFICATION = True

VERBOSE = False  # Set True to see GPT Researcher internal logs

# DATABASE PATH - UPDATE THIS IF YOU ADDED PATHWAYS
# CURRENT SETTING: Using AI-enhanced database (with existing justifications)
DEFAULT_DB_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026\daniel_ai_enhanced_13_04_2026.db"

# Output directory (new copy will be created here)
DEFAULT_OUTPUT_DIR = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\FinnPrio\FinnPRIO_development\databases\daniel_database_2026"

# Filter by EPPO codes (empty list = process all species)
# Example: EPPOCODES_TO_POPULATE = ["XYLEFA", "ANOLGL", "DROSSU"]
EPPOCODES_TO_POPULATE = [ ]

# Filter by question code (None = process all questions)
# Example: QUESTION_FILTER = "EST2"  # Only process EST2
# Pathway questions: "ENT2", "ENT2B", "ENT3", "ENT4"
QUESTION_FILTER = None

# =============================================================================
# HYBRID RESEARCH - LOCAL DOCUMENTS CONFIGURATION
# =============================================================================

# Base path where species folders with PDFs are stored
SPECIES_DOCS_BASE_PATH = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\Prosjektdata - Dokumenter\VKM Data\26.08.2024_lopende_oppdrag_plantehelse\Species"

# Temp folder name for GPT Researcher local docs (created in script directory)
TEMP_DOCS_FOLDER = "my-docs"

# File extensions to include in hybrid research
DOCUMENT_EXTENSIONS = {".pdf", ".txt", ".docx", ".doc"}

# Filename patterns to EXCLUDE from the research corpus.
# These patterns match AI-generated outputs from previous runs (which would
# create a circular feedback loop) and have been observed to crash native
# document loaders (e.g., UnstructuredWordDocumentLoader on .docx).
EXCLUDED_FILENAME_PATTERNS = [
    "_AI_answers_",   # e.g. "Ceratitis capitata_AI_answers_20250430_143728.docx"
    "_AI_generated_",
    "_GPTResearcher_",
]

# =============================================================================
# API Keys - Read from files
OPENAI_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\tore_vkm_openai.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\Tavily_key.txt"

# Load API keys from files
def load_api_key(file_path: str) -> str:
    """Load API key from file, stripping whitespace"""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        print(f"⚠️  Warning: API key file not found: {file_path}")
        return ""

os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)
# =============================================================================

# GPT Researcher Configuration
# NOTE: [DEFAULT] = same as gpt_researcher default (no effect, kept for visibility)
#       [UNUSED]  = only applies to report_type="deep", not "research_report"
#       Active overrides: TEMPERATURE (0.1 vs 0.4), MAX_SEARCH_RESULTS_PER_QUERY (10 vs 5), TOTAL_WORDS (500 vs 1200), CURATE_SOURCES (true vs false)
os.environ.update({
    "TEMPERATURE": "0.1",               # Default: 0.4 — lower for deterministic output
    "FAST_LLM": "openai:gpt-4o-mini",   # [DEFAULT] Quick tasks: summarization, sub-queries
    "SMART_LLM": "openai:gpt-4.1",      # [DEFAULT] Complex reasoning: report writing (long response support)
    "STRATEGIC_LLM": "openai:o4-mini",  # [DEFAULT] Planning: agent/query selection
    "FAST_TOKEN_LIMIT": "3000",         # [DEFAULT]
    "SMART_TOKEN_LIMIT": "6000",        # [DEFAULT]
    "STRATEGIC_TOKEN_LIMIT": "4000",    # [DEFAULT]
    #"DEEP_RESEARCH_BREADTH": "3",      # [DEFAULT] [UNUSED] only applies to report_type="deep"
    #"DEEP_RESEARCH_DEPTH": "2",        # [DEFAULT] [UNUSED] only applies to report_type="deep"
    "MAX_SEARCH_RESULTS_PER_QUERY": "10",  # Default: 5 — more sources per query
    "MAX_ITERATIONS": "5",              # Default: 3 — more research iterations per sub-query
    "TOTAL_WORDS": "1200",               # Default: 1200 — concise justifications
    "REASONING_EFFORT": "medium",       # [DEFAULT] o-series reasoning level for STRATEGIC_LLM
    "CURATE_SOURCES": "true",           # Default: false — filter irrelevant sources before writing
})

# Excluded domains
EXCLUDED_DOMAINS = [
    "grokipedia.com",
    "wikipedia.org",
]

# =============================================================================
# TEXT CLEANING FUNCTIONS
# =============================================================================

def clean_markdown_formatting(text: str) -> str:
    """Remove markdown formatting and clean up AI-generated text."""

    # Remove markdown headings
    text = re.sub(r'^#+\s+.*$', '', text, flags=re.MULTILINE)

    # Remove bold/italic
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    text = re.sub(r'\*([^*]+)\*', r'\1', text)
    text = re.sub(r'__([^_]+)__', r'\1', text)
    text = re.sub(r'_([^_]+)_', r'\1', text)

    # Remove markdown links
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)

    # Remove markdown tables
    text = re.sub(r'^\s*\|[^\n]+\|\s*$', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\|[\s\-:|]+\|\s*$', '', text, flags=re.MULTILINE)

    # Remove bullet points
    text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*\d+\.\s+', '', text, flags=re.MULTILINE)

    # Remove code blocks
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`([^`]+)`', r'\1', text)

    # Remove horizontal rules
    text = re.sub(r'^[-*_]{3,}$', '', text, flags=re.MULTILINE)

    # Remove separator phrases
    separators = [
        r'---\s*\*\*AI-Generated.*?\*\*\s*---',
        r'\*\*AI-Generated.*?\*\*',
        r'---\s*AI-Generated.*?---',
        r'AI-Generated Supplementary Information.*?\n',
        r'\(GPT Researcher\)',
    ]
    for pattern in separators:
        text = re.sub(pattern, '', text, flags=re.MULTILINE | re.DOTALL)

    # Remove common AI introduction headings (anchored so we only strip
    # standalone section headers, not sentences that mention these words).
    intro_patterns = [
        r'^\s*Introduction[:.]?\s*$',
        r'^\s*Summary[:.]?\s*$',
        r'^\s*Overview[:.]?\s*$',
        r'^This report.*?$',
    ]
    for pattern in intro_patterns:
        text = re.sub(pattern, '', text, flags=re.MULTILINE)

    # Clean up whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'[ \t]+', ' ', text)
    text = re.sub(r'\n ', '\n', text)
    text = re.sub(r' \n', '\n', text)
    text = text.strip()

    return text

# =============================================================================
# LOCAL DOCUMENT FUNCTIONS
# =============================================================================

def get_species_docs_path(eppo_code: str) -> Optional[Path]:
    """Get the species folder path for an EPPO code.
    Returns None if folder doesn't exist."""
    path = Path(SPECIES_DOCS_BASE_PATH) / eppo_code.upper()
    return path if path.exists() else None


def copy_species_docs_to_temp(eppo_code: str) -> bool:
    """Copy all documents from species folder to temp my-docs folder.

    Returns True if docs were copied, False if no docs found (fallback to web-only).
    """
    # Get script directory for temp folder location
    script_dir = Path(__file__).parent
    temp_path = script_dir / TEMP_DOCS_FOLDER

    # Clear existing temp folder
    if temp_path.exists():
        def _force_remove(func, path, _):
            os.chmod(path, 0o777)
            func(path)
        shutil.rmtree(temp_path, onerror=_force_remove)
    temp_path.mkdir(parents=True, exist_ok=True)
    os.environ['DOC_PATH'] = str(temp_path.absolute())

    # Find species folder
    species_path = get_species_docs_path(eppo_code)
    if not species_path:
        print(f"  ⚠️  No local documents folder found for {eppo_code}")
        return False

    # Recursively find all matching documents, excluding AI-output files
    docs_copied = 0
    excluded = 0
    for ext in DOCUMENT_EXTENSIONS:
        for doc_file in species_path.rglob(f"*{ext}"):
            if not doc_file.is_file():
                continue
            if any(pat in doc_file.name for pat in EXCLUDED_FILENAME_PATTERNS):
                excluded += 1
                continue
            dest_name = f"{docs_copied:04d}_{doc_file.name}"
            try:
                shutil.copy2(doc_file, temp_path / dest_name)
                docs_copied += 1
            except Exception as e:
                print(f"  ⚠️  Failed to copy {doc_file.name}: {e}")

    if excluded:
        print(f"  🚫 Excluded {excluded} AI-generated file(s) from research corpus")

    if docs_copied > 0:
        print(f"  📚 Copied {docs_copied} documents to temp folder")
        return True
    else:
        print(f"  ⚠️  No documents found in {species_path}")
        return False


def cleanup_temp_docs():
    """Remove temp my-docs folder and clear the in-memory document cache."""
    clear_doc_cache()
    script_dir = Path(__file__).parent
    temp_path = script_dir / TEMP_DOCS_FOLDER
    if temp_path.exists():
        try:
            shutil.rmtree(temp_path)
            print("🧹 Cleaned up temp documents folder")
        except Exception as e:
            print(f"⚠️  Failed to cleanup temp folder: {e}")


# =============================================================================
# DATABASE FUNCTIONS - GENERAL
# =============================================================================

def copy_database(source_path: str, output_dir: str) -> str:
    """Copy source database to a versioned, timestamped destination.

    Names follow `{base}_v{NNN}_{ISO8601}.db`, e.g.
        daniel_v002_2026-04-14T15-42-31.db

    Version is auto-incremented based on existing `{base}_v*_*.db` files in
    `output_dir`. Timestamp uses ISO 8601 with ':' replaced by '-' so the
    filename is valid on Windows. Both parts together guarantee every run
    produces a unique, chronologically sortable, reproducible identifier.
    """
    source_file = Path(source_path)
    original_name = source_file.stem

    # Strip any existing versioned suffix first, then the legacy
    # `_ai_enhanced_...` suffix, to recover a clean base name.
    base_name = re.sub(r'_v\d+_\d{4}-\d{2}-\d{2}T.*$', '', original_name)
    base_name = re.sub(r'_ai_enhanced_.*$', '', base_name)

    output_dir_path = Path(output_dir)
    output_dir_path.mkdir(parents=True, exist_ok=True)

    # Next version: max existing + 1, or 1 if no prior versions exist.
    existing_versions = []
    for f in output_dir_path.glob(f"{base_name}_v*_*.db"):
        m = re.match(rf'{re.escape(base_name)}_v(\d+)_', f.stem)
        if m:
            existing_versions.append(int(m.group(1)))
    next_version = (max(existing_versions) + 1) if existing_versions else 1

    # ISO 8601 timestamp, filesystem-safe (colons → hyphens).
    timestamp = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")

    output_name = f"{base_name}_v{next_version:03d}_{timestamp}.db"
    output_path = output_dir_path / output_name

    # Safety guard: copying a file onto itself corrupts it. With seconds-level
    # timestamps this is virtually impossible, but keep the check.
    if source_file.resolve() == output_path.resolve():
        print(f"\n📋 Source and destination resolve to the same file; reusing it.")
        print(f"   Path: {output_path}")
        return str(output_path)

    print(f"\n📋 Copying database...")
    print(f"   From: {source_path}")
    print(f"   To:   {output_path}")

    shutil.copy2(source_path, output_path)

    if output_path.exists():
        print(f"✅ Database copied ({output_path.stat().st_size / 1024:.1f} KB)")
    else:
        raise FileNotFoundError(f"Failed to copy database to {output_path}")

    return str(output_path)

def get_all_assessment_ids(db_path: str, eppo_codes: List[str] = None) -> List[int]:
    """Get all assessment IDs, optionally filtered by EPPO codes."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        if eppo_codes:
            # Filter by EPPO codes (case-insensitive)
            placeholders = ','.join(['?' for _ in eppo_codes])
            cursor.execute(f"""
                SELECT a.idAssessment
                FROM assessments a
                JOIN pests p ON a.idPest = p.idPest
                WHERE UPPER(p.eppoCode) IN ({placeholders})
                ORDER BY a.idAssessment
            """, [code.upper() for code in eppo_codes])
        else:
            cursor.execute("""
                SELECT idAssessment
                FROM assessments
                ORDER BY idAssessment
            """)

        return [row[0] for row in cursor.fetchall()]
    finally:
        conn.close()


def get_eppo_codes_for_assessments(db_path: str, assessment_ids: List[int]) -> List[str]:
    """Get EPPO codes for a list of assessment IDs."""
    if not assessment_ids:
        return []
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()
        placeholders = ','.join(['?' for _ in assessment_ids])
        cursor.execute(f"""
            SELECT DISTINCT p.eppoCode
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE a.idAssessment IN ({placeholders})
        """, assessment_ids)
        return [row[0] for row in cursor.fetchall() if row[0]]
    finally:
        conn.close()

def get_assessment_info(db_path: str, assessment_id: int) -> Dict:
    """Get assessment details including pest and regular questions."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        # Get assessment with hosts (hosts is in assessments table)
        cursor.execute("""
            SELECT a.idAssessment, a.idPest, p.scientificName, p.eppoCode, a.hosts
            FROM assessments a
            JOIN pests p ON a.idPest = p.idPest
            WHERE a.idAssessment = ?
        """, (assessment_id,))

        result = cursor.fetchone()

        if not result:
            return None

        assessment_id, pest_id, pest_name, eppo_code, hosts = result

        # Get regular questions
        cursor.execute("""
            SELECT a.idAnswer, q.idQuestion, q."group", q.number, q.subgroup,
                   q.question, q.info, a.justification
            FROM answers a
            JOIN questions q ON a.idQuestion = q.idQuestion
            WHERE a.idAssessment = ?
            ORDER BY q.idQuestion
        """, (assessment_id,))

        answers = []
        for row in cursor.fetchall():
            id_answer, id_question, grp, num, subgrp, text, info, justification = row
            code = f"{grp}{num}.{subgrp}" if subgrp else f"{grp}{num}."
            answers.append({
                'idAnswer': id_answer,
                'code': code,
                'text': text,
                'info': info or "",
                'existing_justification': justification or ""
            })

        return {
            'idAssessment': assessment_id,
            'idPest': pest_id,
            'scientificName': pest_name,
            'eppoCode': eppo_code,
            'hosts': hosts or "",
            'answers': answers
        }
    finally:
        conn.close()

def update_answer_justification(db_path: str, id_answer: int, justification: str):
    """Update justification in answers table."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        # Verify table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='answers'")
        if not cursor.fetchone():
            raise Exception(f"Table 'answers' not found in database: {db_path}")

        cursor.execute("UPDATE answers SET justification = ? WHERE idAnswer = ?",
                      (justification, id_answer))
        conn.commit()
    except Exception as e:
        print(f"  ⚠️  Database error in update_answer_justification:")
        print(f"     Database: {db_path}")
        print(f"     Answer ID: {id_answer}")
        print(f"     Error: {e}")
        raise
    finally:
        conn.close()

# =============================================================================
# DATABASE FUNCTIONS - PATHWAYS
# =============================================================================

def get_assessment_pathways(db_path: str, assessment_id: int) -> List[Dict]:
    """Get all selected pathways for an assessment."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT ep.idEntryPathway, ep.idPathway, p.name, p."group", ep.specification
            FROM entryPathways ep
            JOIN pathways p ON ep.idPathway = p.idPathway
            WHERE ep.idAssessment = ?
            ORDER BY p.idPathway
        """, (assessment_id,))

        pathways = []
        for row in cursor.fetchall():
            id_entry, id_pathway, name, group, spec = row
            pathways.append({
                'idEntryPathway': id_entry,
                'idPathway': id_pathway,
                'name': name,
                'group': group,
                'specification': spec or ""
            })

        return pathways
    finally:
        conn.close()

def get_pathway_questions(db_path: str) -> List[Dict]:
    """Get all pathway questions (ENT2A, ENT2B, ENT3, ENT4)."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT idPathQuestion, "group", number, question, info
            FROM pathwayQuestions
            ORDER BY idPathQuestion
        """)

        questions = []
        for row in cursor.fetchall():
            id_q, grp, num, text, info = row
            code = f"{grp}{num}"
            questions.append({
                'idPathQuestion': id_q,
                'code': code,
                'text': text,
                'info': info or ""
            })

        return questions
    finally:
        conn.close()

def get_existing_pathway_justification(db_path: str, id_entry_pathway: int,
                                       id_path_question: int) -> str:
    """Get existing pathway justification."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT justification FROM pathwayAnswers
            WHERE idEntryPathway = ? AND idPathQuestion = ?
        """, (id_entry_pathway, id_path_question))
        result = cursor.fetchone()
        return result[0] if result and result[0] else ""
    finally:
        conn.close()

def update_pathway_justification(db_path: str, id_entry_pathway: int,
                                 id_path_question: int, justification: str):
    """Update or insert pathway justification."""
    conn = sqlite3.connect(db_path)
    try:
        cursor = conn.cursor()

        # Verify table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='pathwayAnswers'")
        if not cursor.fetchone():
            raise Exception(f"Table 'pathwayAnswers' not found in database: {db_path}")

        # Check if exists
        cursor.execute("""
            SELECT idPathAnswer FROM pathwayAnswers
            WHERE idEntryPathway = ? AND idPathQuestion = ?
        """, (id_entry_pathway, id_path_question))

        result = cursor.fetchone()

        if result:
            cursor.execute("""
                UPDATE pathwayAnswers SET justification = ?
                WHERE idPathAnswer = ?
            """, (justification, result[0]))
        else:
            cursor.execute("""
                INSERT INTO pathwayAnswers (idEntryPathway, idPathQuestion, justification)
                VALUES (?, ?, ?)
            """, (id_entry_pathway, id_path_question, justification))

        conn.commit()
    except Exception as e:
        print(f"  ⚠️  Database error in update_pathway_justification:")
        print(f"     Database: {db_path}")
        print(f"     EntryPathway ID: {id_entry_pathway}, PathQuestion ID: {id_path_question}")
        print(f"     Error: {e}")
        raise
    finally:
        conn.close()

# =============================================================================
# QUESTION-SPECIFIC INSTRUCTIONS
# =============================================================================

def get_question_specific_instructions(question_code: str, pest_name: str,
                                       pathway_name: str = None, hosts: str = None) -> str:
    """Get research instructions from Rmd-derived JSON. Returns None if question not found (e.g. IMP2.x)."""
    try:
        return build_justification_prompt(question_code, pest_name, pathway_name, hosts)
    except KeyError:
        print(f"  ⚠️  No Rmd instructions for {question_code}, using database question text")
        return None

# =============================================================================
# GPT RESEARCHER FUNCTIONS
# =============================================================================

def create_research_query(pest_name: str, question_code: str, question_text: str,
                          question_info: str = "", pathway_name: str = None,
                          hosts: str = None) -> str:
    """Create targeted research query.

    Note: question_info from database is IGNORED when Rmd instructions are available,
    as the Rmd provides more accurate and up-to-date guidance.
    """

    # Get specific instructions from Rmd (preferred) or hardcoded fallback
    specific = get_question_specific_instructions(question_code, pest_name, pathway_name, hosts)

    # Check if we got Rmd instructions (they include "QUESTION" header)
    using_rmd_instructions = specific and "QUESTION" in specific

    # Build query
    pathway_text = f' via the pathway "{pathway_name}"' if pathway_name else ""

    # If using Rmd instructions, the 'specific' prompt already contains everything needed
    if using_rmd_instructions:
        query = f"""
Research the following pest for a risk assessment:

PEST: {pest_name}{pathway_text}

{specific}

CRITICAL: Answer ONLY this specific question. Do NOT include information about other topics.

SCOPE LIMITATION:
- Answer based on documented information for THIS EXACT SPECIES only
- Do NOT extrapolate from related species, congeners, or sister taxa
- Do NOT assume biology, hosts, or behavior based on similar species
- If information is limited for this species, acknowledge it clearly
- "Unknown" or "insufficient data for this species" is a valid answer

RESEARCH REQUIREMENTS:
- Base on peer-reviewed literature, official risk assessments (VKM, Fera, EPPO, EFSA, CABI, USDA, and others)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (300-400 words)

INSUFFICIENT INFORMATION:
- If the provided context contains insufficient information to answer the question, explicitly state: "The provided context contains insufficient information to answer the question."
- After stating this, you may provide relevant context that IS available, but clearly note the information gaps

ASSUMPTIONS:
- If making any assumptions, clearly indicate them with phrases like:
  * "Assuming that..."
  * "Based on the assumption that..."
  * "It is assumed that..."
- Clearly distinguish between evidence-based statements and assumptions

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown (#, ##, **, *, -)
- DO NOT use tables - they are unreadable in plain text
- DO NOT include "Introduction" sections
- Answer the question DIRECTLY
- Use paragraph format with proper punctuation
- Citations in parentheses: (Author, Year)
- Write as continuous text, not lists
- If multiple items, write in sentence form

Provide a clear, evidence-based justification.
"""
    else:
        # Fallback: use old format with database question_info
        query = f"""
Research the following question about {pest_name}{pathway_text}:

QUESTION ({question_code}): {question_text}

{specific if specific else "Focus on answering this specific question."}

CRITICAL: Answer ONLY this specific question. Do NOT include information about other topics.

SCOPE LIMITATION:
- Answer based on documented information for THIS EXACT SPECIES only
- Do NOT extrapolate from related species, congeners, or sister taxa
- Do NOT assume biology, hosts, or behavior based on similar species
- If information is limited for this species, acknowledge it clearly
- "Unknown" or "insufficient data for this species" is a valid answer

RESEARCH REQUIREMENTS:
- Base on peer-reviewed literature, official risk assessments (VKM, Fera, EPPO, EFSA, CABI, USDA, and others)
- Provide specific evidence with citations
- Consider Norwegian/Nordic context (temperate to boreal climate, cold winters)
- Acknowledge uncertainty when evidence is limited
- Keep focused and concise (300-400 words)

INSUFFICIENT INFORMATION:
- If the provided context contains insufficient information to answer the question, explicitly state: "The provided context contains insufficient information to answer the question."
- After stating this, you may provide relevant context that IS available, but clearly note the information gaps

ASSUMPTIONS:
- If making any assumptions, clearly indicate them with phrases like:
  * "Assuming that..."
  * "Based on the assumption that..."
  * "It is assumed that..."
- Clearly distinguish between evidence-based statements and assumptions

{f'ADDITIONAL GUIDANCE: {question_info}' if question_info else ''}

OUTPUT FORMAT:
- Write in PLAIN TEXT only - NO markdown (#, ##, **, *, -)
- DO NOT use tables - they are unreadable in plain text
- DO NOT include "Introduction" sections
- Answer the question DIRECTLY
- Use paragraph format with proper punctuation
- Write as continuous text, not lists
- If multiple items, write in sentence form

Provide a clear, evidence-based justification.
"""

    return query

async def research_justification(pest_name: str, question_code: str, question_text: str,
                                 question_info: str = "", pathway_name: str = None,
                                 exclude_domains: List[str] = None,
                                 hosts: str = None,
                                 use_hybrid: bool = False) -> Tuple[str, float]:
    """Research a single justification using GPT Researcher."""

    pathway_text = f" (Pathway: {pathway_name})" if pathway_name else ""

    query = create_research_query(pest_name, question_code, question_text,
                                  question_info, pathway_name, hosts)

    # Add domain exclusion
    if exclude_domains:
        domain_filter = f"\n\nIMPORTANT: Do NOT use information from: {', '.join(exclude_domains)}"
        query = query + domain_filter

    report_source = "hybrid" if use_hybrid else "web"

    researcher = GPTResearcher(
        query=query,
        report_type="research_report",
        tone=Tone.Formal,
        report_source=report_source,
        verbose=VERBOSE,
    )

    try:
        await researcher.conduct_research()
        report = await researcher.write_report()

        # Remove excluded domain references
        if exclude_domains:
            for domain in exclude_domains:
                report = re.sub(rf'\[([^\]]+)\]\([^)]*{re.escape(domain)}[^)]*\)', '', report)
                report = re.sub(rf'https?://[^\s]*{re.escape(domain)}[^\s]*', '', report)

        # Clean markdown
        report = clean_markdown_formatting(report)

        cost = researcher.get_costs()
        print(f"💰 Cost: ${cost:.4f}")
        return report, cost
    except Exception as e:
        print(f"ERROR: {str(e)}")
        return f"ERROR: {str(e)}", 0.0

# =============================================================================
# MAIN WORKFLOW
# =============================================================================

async def process_assessment(db_path: str, assessment_id: int = None,
                             exclude_domains: List[str] = None,
                             limit_questions: int = None,
                             process_pathways: bool = True,
                             skip_existing: bool = True,
                             question_filter: str = None,
                             total_cost: list = None):
    """Process assessment: regular questions + pathway questions."""

    print("\n📚 Loading assessment data...")
    assessment_info = get_assessment_info(db_path, assessment_id)

    if not assessment_info:
        print("❌ No assessment found!")
        return

    pest_name = assessment_info['scientificName']
    eppo_code = assessment_info['eppoCode']
    answers = assessment_info['answers']
    assessment_id = assessment_info['idAssessment']
    hosts = assessment_info.get('hosts', '')
    # Set up local documents for hybrid research
    use_hybrid = copy_species_docs_to_temp(eppo_code)
    assessment_cost = 0.0
    try:
        if question_filter:
            # Filter to specific question code (e.g., EST2, ENT2A)
            # Strip trailing dots for comparison (codes stored as "EST2." but user enters "EST2")
            filter_code = question_filter.upper().rstrip('.')
            answers = [a for a in answers if a['code'].upper().rstrip('.') == filter_code]
            print(f"🔍 Filtering to question: {filter_code}")
            if not answers:
                print(f"⚠️  No matching regular question found for {filter_code}")

        if limit_questions:
            answers = answers[:limit_questions]
            print(f"⚠️  Limited to {limit_questions} questions")

        print(f"\n📊 Assessment: {pest_name} ({eppo_code})")
        print(f"📊 Regular questions: {len(answers)}")
        if hosts:
            print(f"🌱 Hosts: {hosts[:100]}{'...' if len(hosts) > 100 else ''}")

        # Process regular questions
        print("\n" + "=" * 80)
        print("PROCESSING REGULAR QUESTIONS")
        print("=" * 80)

        for i, answer in enumerate(answers, 1):
            print(f"\n[{i}/{len(answers)}] {answer['code']}")

            existing = answer['existing_justification']
            if existing:
                print(f"📄 Found existing ({len(existing)} chars)")
                if skip_existing:
                    print(f"⏭️  Skipped (existing justification)")
                    continue

            try:
                ai_text, call_cost = await research_justification(
                    pest_name=pest_name,
                    question_code=answer['code'],
                    question_text=answer['text'],
                    question_info=answer['info'],
                    exclude_domains=exclude_domains or [],
                    hosts=hosts,
                    use_hybrid=use_hybrid
                )
                assessment_cost += call_cost

                combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                update_answer_justification(db_path, answer['idAnswer'], combined)

                preview = ai_text[:200].replace('\n', ' ')
                print(f"✅ Saved: {preview}...")
            except Exception as e:
                print(f"❌ Error: {str(e)}")

        # Process pathway questions
        if process_pathways:
            try:
                pathways = get_assessment_pathways(db_path, assessment_id)
            except Exception as e:
                print(f"\n⚠️  Error getting pathways: {e}")
                pathways = []

            if pathways:
                print(f"\n{'=' * 80}")
                print(f"PROCESSING PATHWAY QUESTIONS ({len(pathways)} pathways)")
                print(f"{'=' * 80}")

                try:
                    pathway_questions = get_pathway_questions(db_path)
                except Exception as e:
                    print(f"\n⚠️  Error getting pathway questions: {e}")
                    return

                # Filter pathway questions if question_filter is set
                if question_filter:
                    filter_code = question_filter.upper().rstrip('.')
                    pathway_questions = [pq for pq in pathway_questions
                                        if pq['code'].upper().rstrip('.') == filter_code]
                    if not pathway_questions:
                        print(f"⚠️  No matching pathway question found for {filter_code}")

                total = len(pathways) * len(pathway_questions)
                count = 0

                for pathway in pathways:
                    pathway_name = pathway['name']
                    print(f"\n📍 Pathway: {pathway_name}")

                    for pq in pathway_questions:
                        count += 1
                        print(f"\n[{count}/{total}] {pq['code']} for {pathway_name}")

                        existing = get_existing_pathway_justification(
                            db_path, pathway['idEntryPathway'], pq['idPathQuestion'])

                        if existing:
                            print(f"📄 Found existing ({len(existing)} chars)")
                            if skip_existing:
                                print(f"⏭️  Skipped (existing justification)")
                                continue

                        try:
                            ai_text, call_cost = await research_justification(
                                pest_name=pest_name,
                                question_code=pq['code'],
                                question_text=pq['text'],
                                question_info=pq['info'],
                                pathway_name=pathway_name,
                                exclude_domains=exclude_domains or [],
                                hosts=hosts,
                                use_hybrid=use_hybrid
                            )
                            assessment_cost += call_cost

                            combined = f"{existing}\n\n{ai_text}" if existing else ai_text
                            update_pathway_justification(
                                db_path, pathway['idEntryPathway'],
                                pq['idPathQuestion'], combined)

                            preview = ai_text[:2000].replace('\n', ' ')
                            print(f"✅ Saved: {preview}...")
                        except Exception as e:
                            print(f"❌ Error: {str(e)}")
            else:
                print("\nℹ️  No pathways selected for this assessment")
    finally:
        cleanup_temp_docs()
        if total_cost is not None:
            total_cost[0] += assessment_cost
        print(f"💰 Assessment total: ${assessment_cost:.4f}")

async def main(source_db: str = DEFAULT_DB_PATH,
               output_dir: str = DEFAULT_OUTPUT_DIR,
               assessment_id: int = None,
               limit_questions: int = None,
               exclude_domains: List[str] = None,
               process_pathways: bool = True,
               skip_existing: bool = None,
               eppo_codes: List[str] = None,
               question_filter: str = None):
    """Main workflow."""

    # Use configuration value if not explicitly set via command line
    if skip_existing is None:
        skip_existing = SKIP_EXISTING_JUSTIFICATION

    print("\n" + "=" * 80)
    print("FinnPRIO JUSTIFICATION POPULATOR")
    print("=" * 80)

    print(f"\n📂 Source Database: {source_db}")
    print(f"📂 Skip existing justifications: {skip_existing}")

    if exclude_domains is None:
        exclude_domains = []

    if exclude_domains:
        print(f"\n⛔ Excluded: {', '.join(exclude_domains)}")

    # Determine question filter to use (command-line overrides config)
    effective_question_filter = question_filter if question_filter else QUESTION_FILTER

    # Copy database
    working_db = copy_database(source_db, output_dir)

    print(f"\n✅ Working with: {working_db}")
    print(f"✅ Complete structure preserved")

    # Confirm (skip if filtering to single question or limited questions)
    if not effective_question_filter and (limit_questions is None or limit_questions > 5):
        response = input("\nThis will make many API calls. Continue? (yes/no): ")
        if response.lower() not in ['yes', 'y']:
            print("Cancelled.")
            return

    # Process
    print("\n" + "=" * 80)
    print("STARTING RESEARCH")
    print("=" * 80)
    if skip_existing:
        print("ℹ️  Skip existing justifications: Enabled")
    else:
        print("ℹ️  Existing justifications preserved, AI text appended")
    if process_pathways:
        print("ℹ️  Will process pathway questions for each selected pathway")

    # Determine EPPO codes to use (command-line overrides config)
    effective_eppo_codes = eppo_codes if eppo_codes else (EPPOCODES_TO_POPULATE if EPPOCODES_TO_POPULATE else None)

    if effective_question_filter:
        print(f"🔍 Question filter: {effective_question_filter.upper()} only")

    # Get list of assessments to process
    if assessment_id:
        assessment_ids = [assessment_id]
        print(f"\nℹ️  Processing single assessment: {assessment_id}")
    elif effective_eppo_codes:
        assessment_ids = get_all_assessment_ids(working_db, effective_eppo_codes)
        print(f"\nℹ️  Filtering by EPPO codes: {effective_eppo_codes}")
        print(f"    Found {len(assessment_ids)} matching assessment(s)")
        # Verify all requested codes were found
        if assessment_ids:
            found_codes = get_eppo_codes_for_assessments(working_db, assessment_ids)
            missing = set(c.upper() for c in effective_eppo_codes) - set(c.upper() for c in found_codes)
            if missing:
                print(f"⚠️  Warning: No assessments found for EPPO codes: {missing}")
    else:
        assessment_ids = get_all_assessment_ids(working_db)
        print(f"\nℹ️  Processing all assessments: {len(assessment_ids)} total")

    # Process each assessment
    total_cost = [0.0]
    for idx, aid in enumerate(assessment_ids, 1):
        if len(assessment_ids) > 1:
            print("\n" + "=" * 80)
            print(f"ASSESSMENT {idx}/{len(assessment_ids)} (ID: {aid})")
            print("=" * 80)

        await process_assessment(
            db_path=working_db,
            assessment_id=aid,
            exclude_domains=exclude_domains,
            limit_questions=limit_questions,
            process_pathways=process_pathways,
            skip_existing=skip_existing,
            question_filter=effective_question_filter,
            total_cost=total_cost,
        )

    print(f"💰 Total API cost: ${total_cost[0]:.4f}")
    print("\n" + "=" * 80)
    print("✅ COMPLETED")
    print("=" * 80)
    print(f"\n📁 Database: {working_db}")
    print("\n✅ Regular questions: AI text appended to answers table")
    if process_pathways:
        print("✅ Pathway questions: AI text appended to pathwayAnswers table")
    print("\n🚀 Ready to use in FinnPRIO app!")

# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="FinnPRIO Justification Populator v3")
    parser.add_argument('--db', type=str, default=DEFAULT_DB_PATH)
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument('--assessment-id', type=int, default=None)
    parser.add_argument('--limit-questions', type=int, default=None)
    parser.add_argument('--no-pathways', action='store_true',
                       help='Skip pathway questions')
    parser.add_argument('--question', type=str, default=None,
                       help='Process only specific question code (e.g., --question EST2)')
    parser.add_argument('--eppo-codes', type=str, nargs='+', default=None,
                       help='Filter by EPPO codes (e.g., --eppo-codes XYLEFA ANOLGL)')
    parser.add_argument('--overwrite', action='store_true',
                       help=f'Process questions that already have a justification and APPEND the new AI text (default: skip them; SKIP_EXISTING_JUSTIFICATION={SKIP_EXISTING_JUSTIFICATION})')
    parser.add_argument('--exclude-domains', type=str, nargs='+', default=None)
    parser.add_argument('--no-default-exclusions', action='store_true')

    args = parser.parse_args()

    # Build exclusion list. --no-default-exclusions suppresses the built-in
    # list; --exclude-domains adds on top regardless.
    exclude_domains = [] if args.no_default_exclusions else EXCLUDED_DOMAINS.copy()
    if args.exclude_domains:
        exclude_domains.extend(args.exclude_domains)

    # Determine skip_existing based on command line flag or use config default
    skip_existing = False if args.overwrite else None  # None means use config default

    asyncio.run(main(
        source_db=args.db,
        output_dir=args.output,
        assessment_id=args.assessment_id,
        limit_questions=args.limit_questions,
        exclude_domains=exclude_domains,
        process_pathways=not args.no_pathways,
        skip_existing=skip_existing,
        eppo_codes=args.eppo_codes,
        question_filter=args.question
    ))