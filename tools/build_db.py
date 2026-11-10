#!/usr/bin/env python3
"""Build chinesepopup.koplugin/data/cedict.sqlite from CC-CEDICT.

    python3 tools/build_db.py                       # download the current release
    python3 tools/build_db.py --cedict path/to/cedict_1_0_ts_utf-8_mdbg.txt.gz

No third-party dependencies. The download is kept in build/ (git-ignored) so a
rebuild can reuse it with --cedict.

Schema:
    entries(simp, trad, pinyin, defs)   one row per CC-CEDICT line
        pinyin  tone marks, syllables joined into words: "Zhōngguó"
        defs    senses joined with "/", cross-references made readable
    meta(key, value)                    CC-CEDICT date and entry count
Indexes on simp and trad: the plugin looks up all candidate words of a tap in
one query (WHERE simp IN (...) OR trad IN (...)).

Pinyin conversion and cross-reference cleaning come from the companion plugin
koreader-interlinear-pinyin (tools/pinyin_util.py and tools/build_data.py).

CC-CEDICT: https://www.mdbg.net/chinese/dictionary?page=cc-cedict
(c) MDBG and contributors, CC BY-SA 4.0.
"""
import argparse
import gzip
import hashlib
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.request

URL = "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "chinesepopup.koplugin", "data", "cedict.sqlite")
BUILD_DIR = os.path.join(ROOT, "build")

LINE_RE = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/\s*$")

# ---------------------------------------------------------------------------
# Numbered pinyin -> tone marks (from koreader-interlinear-pinyin pinyin_util.py)
# ---------------------------------------------------------------------------

VOWELS = "aeiouü"
MARKS = {
    "a": "āáǎà", "e": "ēéěè", "i": "īíǐì",
    "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ",
}


def numbered_to_marked(syl):
    """'lu:4' -> 'lǜ', 'zhuang4' -> 'zhuàng', 'ma5' -> 'ma'."""
    syl = syl.lower().replace("u:", "ü").replace("v", "ü")
    tone = 5
    if syl and syl[-1].isdigit():
        tone = int(syl[-1])
        syl = syl[:-1]
    if tone in (5, 0) or not syl:
        return syl
    # Standard placement: a or e take the mark; in "ou" the o does;
    # otherwise the last vowel.
    if "a" in syl:
        idx = syl.index("a")
    elif "e" in syl:
        idx = syl.index("e")
    elif "ou" in syl:
        idx = syl.index("o")
    else:
        idx = max((i for i, c in enumerate(syl) if c in VOWELS), default=-1)
        if idx < 0:  # 'm2', 'ng2', 'r5' ...
            return syl
    return syl[:idx] + MARKS[syl[idx]][tone - 1] + syl[idx + 1:]


def joined_pinyin(numbered):
    """'shen2 me5' -> 'shénme', 'Xi1 an1' -> "Xī'ān" (apostrophe before a, o, e)."""
    if "·" in numbered:  # names: 喬治·奧威爾|乔治·奥威尔[Qiao2 zhi4 · Ao4 wei1 er3]
        return "·".join(joined_pinyin(part) for part in numbered.split("·"))
    out = []
    for i, syl in enumerate(numbered.replace(",", " ").split()):
        capital = syl[:1].isupper()
        marked = numbered_to_marked(syl)
        if capital:
            marked = marked[:1].upper() + marked[1:]
        if i > 0 and capital:  # a new name word: Dong4 wu4 Nong2 chang3 -> Dòngwù Nóngchǎng
            marked = " " + marked
        elif i > 0 and unicodedata.normalize("NFD", marked)[:1].lower() in "aoe":
            marked = "'" + marked
        out.append(marked)
    return "".join(out)


# Cross-references inside CC-CEDICT senses: 夠|够[gou4], 乘[cheng2], [jue2].
XREF_RE = re.compile(r"(?:([^\x00-\x7f\s\[\]|,;:()/]+)(?:\|([^\x00-\x7f\s\[\]|,;:()/]+))?)?\[([A-Za-z0-9:, ·]+)\]")


def clean_sense(sense):
    """'variant of 夠|够[gou4]' -> 'variant of 够 gòu', 'CL:個|个[ge4],隻|只[zhi1]'
    -> 'CL: 个 gè, 只 zhī', 'Taiwan pr. [jue2]' -> 'Taiwan pr. jué'.
    Cross-references show the simplified form (the reader mostly reads modern
    simplified Mandarin)."""
    def repl(m):
        first, second, py = m.groups()
        form = (second or first) if first else ""
        py = joined_pinyin(py)
        return f"{form} {py}" if form else py
    sense = XREF_RE.sub(repl, sense)
    if sense.startswith("CL:"):
        sense = "CL: " + ", ".join(p.strip() for p in sense[3:].split(","))
    return sense.replace("\t", " ").strip()


# ---------------------------------------------------------------------------


def opener(path):
    return gzip.open(path, "rt", encoding="utf-8") if path.endswith(".gz") else open(path, encoding="utf-8")


def read_cedict(path):
    header, entries = {}, []
    with opener(path) as f:
        for line in f:
            if line.startswith("#"):
                if line.startswith("#! ") and "=" in line:
                    key, value = line[3:].strip().split("=", 1)
                    header[key] = value
                continue
            m = LINE_RE.match(line.strip())
            if not m:
                continue
            trad, simp, py, defs = m.groups()
            senses = [clean_sense(s) for s in defs.split("/") if s.strip()]
            entries.append((simp, trad, joined_pinyin(py), "/".join(senses)))
    return header, entries


def download():
    os.makedirs(BUILD_DIR, exist_ok=True)
    path = os.path.join(BUILD_DIR, os.path.basename(URL))
    print(f"Downloading {URL}")
    req = urllib.request.Request(URL, headers={"User-Agent": "koreader-chinese-popup build script"})
    with urllib.request.urlopen(req, timeout=120) as r, open(path, "wb") as f:
        f.write(r.read())
    return path


def build(entries, header, out):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    con = sqlite3.connect(tmp)
    con.executescript("""
        PRAGMA page_size = 4096;
        CREATE TABLE entries (simp TEXT NOT NULL, trad TEXT NOT NULL, pinyin TEXT NOT NULL, defs TEXT NOT NULL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    con.executemany("INSERT INTO entries VALUES (?, ?, ?, ?)", entries)
    con.execute("CREATE INDEX entries_simp ON entries(simp)")
    con.execute("CREATE INDEX entries_trad ON entries(trad)")
    meta = {"source": "CC-CEDICT", "license": "CC BY-SA 4.0",
            "cedict_date": header.get("date", ""), "cedict_entries": str(len(entries))}
    con.executemany("INSERT INTO meta VALUES (?, ?)", meta.items())
    con.commit()
    con.execute("VACUUM")
    con.close()
    os.replace(tmp, out)


def lookup_sql(n):
    """The plugin's lookup query for n candidate words (keep in step with
    DB.sql in chinesepopup.koplugin/cp_db.lua)."""
    marks = ",".join("?" * n)
    return (f"SELECT simp, trad, pinyin, defs FROM entries WHERE simp IN ({marks}) "
            f"OR trad IN ({marks}) ORDER BY rowid")


def check_query_plan(path):
    """Fail the build unless the lookup query searches both indexes (no full
    table scan), for the smallest and largest candidate counts."""
    con = sqlite3.connect(path)
    try:
        for n in (1, 36):
            plan = [row[3] for row in con.execute("EXPLAIN QUERY PLAN " + lookup_sql(n), ["x"] * (2 * n))]
            text = "\n".join(plan)
            ok = ("USING INDEX entries_simp" in text and "USING INDEX entries_trad" in text
                  and "SCAN entries" not in text)
            if not ok:
                sys.exit(f"Lookup query for {n} words does not use the indexes:\n{text}")
        print("Query plan: both indexes used (" + "; ".join(plan) + ")")
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cedict", help="local CC-CEDICT file (.txt or .txt.gz); downloaded when omitted")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()
    path = args.cedict or download()
    with open(path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    header, entries = read_cedict(path)
    if len(entries) < 100000:
        sys.exit(f"Only {len(entries)} entries read from {path}; is it CC-CEDICT?")
    build(entries, header, args.out)
    check_query_plan(args.out)
    size = os.path.getsize(args.out)
    print(f"CC-CEDICT {header.get('date', '(no date)')}: {len(entries)} entries, SHA-256 {sha}")
    print(f"Wrote {args.out} ({size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
