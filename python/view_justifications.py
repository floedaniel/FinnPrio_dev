"""
Utility script to view and export justifications from the output database.
"""

import sqlite3
import sys
from pathlib import Path
from datetime import datetime


def find_latest_database(output_dir: str = "outputs") -> str:
    """Find the most recent justifications database."""
    output_path = Path(output_dir)
    db_files = list(output_path.glob("justifications_*.db"))

    if not db_files:
        raise FileNotFoundError(f"No justification databases found in {output_dir}")

    # Sort by modification time, return latest
    latest = max(db_files, key=lambda p: p.stat().st_mtime)
    return str(latest)


def view_summary(db_path: str):
    """Print summary statistics of the justifications database."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    print("\n" + "=" * 80)
    print(f"JUSTIFICATIONS DATABASE SUMMARY")
    print("=" * 80)
    print(f"Database: {db_path}")

    # Total justifications
    cursor.execute("SELECT COUNT(*) FROM justifications")
    total = cursor.fetchone()[0]
    print(f"\nTotal entries: {total}")

    # By status
    cursor.execute("SELECT status, COUNT(*) FROM justifications GROUP BY status")
    print("\nBy status:")
    for status, count in cursor.fetchall():
        print(f"  {status}: {count}")

    # By pest
    cursor.execute("""
        SELECT scientificName, eppoCode, COUNT(*) as count
        FROM justifications
        GROUP BY scientificName
        ORDER BY scientificName
    """)
    print("\nBy pest:")
    for name, code, count in cursor.fetchall():
        print(f"  {name} ({code}): {count} justifications")

    # By question
    cursor.execute("""
        SELECT questionCode, COUNT(*) as count
        FROM justifications
        GROUP BY questionCode
        ORDER BY questionCode
    """)
    print("\nBy question:")
    for code, count in cursor.fetchall():
        print(f"  {code}: {count} justifications")

    conn.close()


def view_pest_justifications(db_path: str, pest_name: str = None, pest_id: int = None):
    """View all justifications for a specific pest."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    if pest_id:
        cursor.execute("""
            SELECT scientificName, eppoCode, questionCode, questionText,
                   substr(justification, 1, 200), status
            FROM justifications
            WHERE idPest = ?
            ORDER BY questionCode
        """, (pest_id,))
    elif pest_name:
        cursor.execute("""
            SELECT scientificName, eppoCode, questionCode, questionText,
                   substr(justification, 1, 200), status
            FROM justifications
            WHERE scientificName LIKE ?
            ORDER BY questionCode
        """, (f"%{pest_name}%",))
    else:
        print("Error: Must provide either pest_name or pest_id")
        conn.close()
        return

    results = cursor.fetchall()

    if not results:
        print(f"No justifications found for pest: {pest_name or pest_id}")
        conn.close()
        return

    print("\n" + "=" * 80)
    print(f"JUSTIFICATIONS FOR: {results[0][0]} ({results[0][1]})")
    print("=" * 80)

    for _, _, q_code, q_text, preview, status in results:
        print(f"\n[{q_code}] {q_text}")
        print(f"Status: {status}")
        print(f"Preview: {preview}...")
        print("-" * 80)

    conn.close()


def view_full_justification(db_path: str, pest_name: str, question_code: str):
    """View a single justification in full."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT scientificName, eppoCode, questionCode, questionText, justification, timestamp, status
        FROM justifications
        WHERE scientificName LIKE ? AND questionCode = ?
    """, (f"%{pest_name}%", question_code))

    result = cursor.fetchone()

    if not result:
        print(f"No justification found for {pest_name} - {question_code}")
        conn.close()
        return

    name, eppo, code, question, justification, timestamp, status = result

    print("\n" + "=" * 80)
    print(f"FULL JUSTIFICATION")
    print("=" * 80)
    print(f"Pest: {name} ({eppo})")
    print(f"Question: [{code}] {question}")
    print(f"Status: {status}")
    print(f"Generated: {timestamp}")
    print("=" * 80)
    print("\n" + justification)
    print("\n" + "=" * 80)

    conn.close()


def export_to_csv(db_path: str, output_file: str = None):
    """Export all justifications to CSV."""
    import csv

    if not output_file:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_file = f"justifications_export_{timestamp}.csv"

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT idPest, scientificName, eppoCode, questionCode, questionText, justification, timestamp, status
        FROM justifications
        ORDER BY idPest, questionCode
    """)

    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['idPest', 'scientificName', 'eppoCode', 'questionCode',
                        'questionText', 'justification', 'timestamp', 'status'])
        writer.writerows(cursor.fetchall())

    conn.close()
    print(f"\n✅ Exported to: {output_file}")


def export_to_json(db_path: str, output_file: str = None):
    """Export all justifications to JSON."""
    import json

    if not output_file:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_file = f"justifications_export_{timestamp}.json"

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT idPest, scientificName, eppoCode, questionCode, questionText, justification, timestamp, status
        FROM justifications
        ORDER BY idPest, questionCode
    """)

    results = []
    for row in cursor.fetchall():
        results.append({
            'idPest': row[0],
            'scientificName': row[1],
            'eppoCode': row[2],
            'questionCode': row[3],
            'questionText': row[4],
            'justification': row[5],
            'timestamp': row[6],
            'status': row[7]
        })

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    conn.close()
    print(f"\n✅ Exported to: {output_file}")


def list_all_pests(db_path: str):
    """List all unique pests in the database."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT DISTINCT idPest, scientificName, eppoCode
        FROM justifications
        ORDER BY idPest
    """)

    print("\n" + "=" * 80)
    print("AVAILABLE PESTS")
    print("=" * 80)

    for pest_id, name, code in cursor.fetchall():
        print(f"{pest_id:3} | {name:50} | {code}")

    conn.close()


# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

def main():
    """Interactive command-line interface."""

    if len(sys.argv) == 1:
        # No arguments - show help
        print("\n" + "=" * 80)
        print("JUSTIFICATIONS VIEWER")
        print("=" * 80)
        print("\nUsage:")
        print("  python view_justifications.py summary")
        print("  python view_justifications.py list")
        print("  python view_justifications.py pest <scientific_name>")
        print("  python view_justifications.py view <scientific_name> <question_code>")
        print("  python view_justifications.py export-csv [filename]")
        print("  python view_justifications.py export-json [filename]")
        print("\nExamples:")
        print("  python view_justifications.py summary")
        print("  python view_justifications.py list")
        print("  python view_justifications.py pest Ralstonia")
        print("  python view_justifications.py view Ralstonia ENT1")
        print("  python view_justifications.py export-csv results.csv")
        return

    # Find latest database
    try:
        db_path = find_latest_database()
    except FileNotFoundError as e:
        print(f"\n❌ Error: {e}")
        print("Make sure you have run the justification population script first.")
        return

    command = sys.argv[1].lower()

    if command == "summary":
        view_summary(db_path)

    elif command == "list":
        list_all_pests(db_path)

    elif command == "pest":
        if len(sys.argv) < 3:
            print("Error: Please provide pest name")
            print("Usage: python view_justifications.py pest <scientific_name>")
            return
        pest_name = " ".join(sys.argv[2:])
        view_pest_justifications(db_path, pest_name=pest_name)

    elif command == "view":
        if len(sys.argv) < 4:
            print("Error: Please provide pest name and question code")
            print("Usage: python view_justifications.py view <scientific_name> <question_code>")
            return
        pest_name = sys.argv[2]
        question_code = sys.argv[3]
        view_full_justification(db_path, pest_name, question_code)

    elif command == "export-csv":
        output_file = sys.argv[2] if len(sys.argv) > 2 else None
        export_to_csv(db_path, output_file)

    elif command == "export-json":
        output_file = sys.argv[2] if len(sys.argv) > 2 else None
        export_to_json(db_path, output_file)

    else:
        print(f"Unknown command: {command}")
        print("Run without arguments to see usage help")


if __name__ == "__main__":
    main()
