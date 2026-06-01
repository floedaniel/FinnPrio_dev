"""Identify the PDF that crashed the last PDF-loading run and add it to the
bad-files list so it gets skipped on re-run.

Reads .pdf_load_log.txt — the last "LOADING:" line without a matching "  OK:"
is the crashing file. Appends its filename to .pdf_bad_files.txt.

Usage:
    python mark_bad_pdf.py
"""

from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
LOAD_LOG = SCRIPT_DIR / ".pdf_load_log.txt"
BAD_FILES = SCRIPT_DIR / ".pdf_bad_files.txt"


def find_crashed_file():
    if not LOAD_LOG.exists():
        print("No load log found. Nothing to mark.")
        return None

    lines = LOAD_LOG.read_text(encoding="utf-8").splitlines()
    last_loading = None
    last_ok = None
    for line in lines:
        if line.startswith("LOADING: "):
            last_loading = line[len("LOADING: "):].strip()
        elif line.startswith("  OK: "):
            last_ok = line[len("  OK: "):].strip()

    if last_loading and last_loading != last_ok:
        return last_loading
    print("No unfinished LOADING entry — last run completed cleanly.")
    return None


def main():
    culprit = find_crashed_file()
    if not culprit:
        return

    filename = Path(culprit).name
    print(f"Crashing file identified: {filename}")
    print(f"  Full path: {culprit}")

    existing = set()
    if BAD_FILES.exists():
        existing = {l.strip() for l in BAD_FILES.read_text(encoding="utf-8").splitlines() if l.strip()}

    if filename in existing:
        print(f"Already in bad-files list. Nothing to do.")
        return

    with open(BAD_FILES, "a", encoding="utf-8") as f:
        f.write(filename + "\n")
    print(f"Added to {BAD_FILES.name}. It will be skipped on next run.")


if __name__ == "__main__":
    main()
