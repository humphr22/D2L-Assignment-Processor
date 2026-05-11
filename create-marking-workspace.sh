#!/usr/bin/env bash
set -euo pipefail

# ================================================= Features:# ============================================================
# - Groups D2L bulk ZIP submissions by student (DDSB filename pattern)
# - Parses index.html (structured) to extract typed text + links into
#   per-student files copied into 07_To_Mark (where you mark) [2](https://ddsbcampus-my.sharepoint.com/personal/jj212581_ddsb_ca/Documents/Microsoft%20Copilot%20Chat%20Files/index.html)
# - Adds heuristics:
#   - LIKELY_FINAL_TEXT
#   - META_NOTE_DETECTED (sorry/late/wrong folder) [2](https://ddsbcampus-my.sharepoint.com/personal/jj212581_ddsb_ca/Documents/Microsoft%20Copilot%20Chat%20Files/index.html)
# - Triage prompts ONLY for image-only students (no doc finals)
# - Builds queue + improved launcher:
#   - shows counts + flags
#   - hides SKIP automatically
#   - records progress (opened/done)
#   - ENTER opens next pending
# - Optional: class list CSV cross-check → not submitted + zeros file
#   (Download-all only includes students who submitted, so this is essential) [1](https://wiki.millersville.edu/spaces/d2ldocs/pages/122754292/Downloading+student+submissions+from+assignments)
# ============================================================

# ---------- Defaults ----------
BASE_DIR="$HOME/Teaching_Marking"
MAKE_IMAGE_PDFS="auto"      # auto|yes|no (uses ImageMagick convert)
PROMPT_MARK_DONE="yes"      # yes|no (after opening a student, prompt to mark DONE)
# ----------------------------

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

safe_name() {
  echo "$1" \
    | sed 's/[[:space:]]\+/_/g' \
    | sed 's#[/\\:*?"<>|]#_#g' \
    | sed 's/_\+/_/g' \
    | sed 's/^_//' \
    | sed 's/_$//'
}

strip_quotes() {
  local s="${1:-}"
  s="$(echo "$s" | sed 's/\r$//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  if [[ "$s" == \'*\' && ${#s} -ge 2 ]]; then s="${s:1:${#s}-2}"; fi
  if [[ "$s" == \"*\" && ${#s} -ge 2 ]]; then s="${s:1:${#s}-2}"; fi
  echo "$s"
}

log_audit() {
  local audit="$1"; shift
  echo "\"$(timestamp)\",\"$*\"" >> "$audit"
}

# Extension detection
is_image_ext() {
  local ext="${1,,}"
  case "$ext" in
    jpg|jpeg|png|webp|heic|heif) return 0 ;;
    *) return 1 ;;
  esac
}

is_doc_ext() {
  local ext="${1,,}"
  case "$ext" in
    pdf|doc|docx|odt|rtf|txt) return 0 ;;
    *) return 1 ;;
  esac
}

# MIME fallback if extension missing/odd
mime_type() {
  command -v file >/dev/null 2>&1 || { echo ""; return 0; }
  file -b --mime-type "$1" 2>/dev/null || echo ""
}

doc_priority() {
  local ext="${1,,}"
  case "$ext" in
    pdf) echo 1 ;;
    docx) echo 2 ;;
    odt) echo 3 ;;
    doc) echo 4 ;;
    rtf) echo 5 ;;
    txt) echo 6 ;;
    *) echo 99 ;;
  esac
}

filesize() { stat -c%s "$1" 2>/dev/null || echo 0; }
have_convert() { command -v convert >/dev/null 2>&1; }

is_better_final() {
  local cand="$1" cand_ext="$2" best="$3" best_ext="$4"
  local pc pb
  pc="$(doc_priority "$cand_ext")"
  pb="$(doc_priority "$best_ext")"
  if (( pc < pb )); then return 0; fi
  if (( pc > pb )); then return 1; fi
  local sc sb
  sc="$(filesize "$cand")"
  sb="$(filesize "$best")"
  (( sc > sb ))
}

make_pdf_from_images() {
  local src_dir="$1"
  local out_pdf="$2"
  shopt -s nullglob
  local imgs=( "$src_dir"/* )
  shopt -u nullglob
  [[ ${#imgs[@]} -eq 0 ]] && return 1
  convert "${imgs[@]}" "$out_pdf" 2>/dev/null
}

# ✅ Fixed student-name parser (Bash regex)
parse_student_from_filename() {
  local base="$1"
  local months='janv\.|févr\.|fevr\.|mars|avr\.|avril|mai|juin|juil\.|août|aout|sept\.|oct\.|nov\.|déc\.|dec\.'
  if [[ "$base" =~ ^[0-9]+-[0-9]+\ -\ (.+)-\ ($months)[[:space:]] ]]; then
    local name="${BASH_REMATCH[1]}"
    name="$(echo "$name" | sed 's/[[:space:]]\+$//' | sed 's/^[[:space:]]\+//')"
    local key
    key="$(safe_name "$name")"
    echo "$name|$key"
    return 0
  fi
  echo "Unknown Student|UnknownStudent"
}

# ============================================================
# START
# ============================================================
echo "============================================================"
echo " D2L Marking Workspace Builder (Local / Linux Mint)"
echo "============================================================"
echo "Base directory: $BASE_DIR"
echo

mkdir -p "$BASE_DIR"

read -rp "Course code (e.g., FSF1D1): " COURSE
read -rp "Assignment name (e.g., Unit 2 Tâche Finale): " ASSIGNMENT
read -rp "Collection date (YYYY-MM-DD): " DATE_STR

COURSE_CLEAN="$(safe_name "$COURSE")"
ASSIGN_CLEAN="$(safe_name "$ASSIGNMENT")"

WORK_NAME="${DATE_STR}_${ASSIGN_CLEAN}"
WORK_DIR="$BASE_DIR/$COURSE_CLEAN/$WORK_NAME"

if [[ -d "$WORK_DIR" ]]; then
  echo
  echo "WARNING: Workspace already exists:"
  echo "  $WORK_DIR"
  echo
  read -rp "Create a timestamped duplicate? (y/n): " DUP
  if [[ "$DUP" =~ ^[Yy]$ ]]; then
    WORK_DIR="${WORK_DIR}_$(date +%Y%m%d_%H%M%S)"
  else
    echo "Cancelled."
    exit 1
  fi
fi

echo
read -rp "Path to D2L downloaded ZIP file: " ZIP_PATH
ZIP_PATH="$(strip_quotes "$ZIP_PATH")"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ERROR: ZIP file not found:"
  echo "  $ZIP_PATH"
  exit 1
fi

echo
read -rp "Optional class list CSV path (ENTER to skip): " CLASSLIST_PATH
CLASSLIST_PATH="$(strip_quotes "$CLASSLIST_PATH")"

# Workspace structure
mkdir -p "$WORK_DIR"/{01_D2L_Original_Zip,02_Extracted_Originals,03_By_Student_Unsorted,04_By_Student_Images,05_By_Student_Final_Docs,05_By_Student_Text_Extracted,06_Image_PDF_Packets,07_To_Mark,08_Needs_Review,09_Reports}

AUDIT="$WORK_DIR/audit_log.csv"
echo "\"Timestamp\",\"Action\"" > "$AUDIT"
log_audit "$AUDIT" "created_workspace $WORK_DIR"
log_audit "$AUDIT" "zip_source $ZIP_PATH"
[[ -n "${CLASSLIST_PATH:-}" ]] && log_audit "$AUDIT" "classlist_path $CLASSLIST_PATH"

# Copy ZIP into workspace
ZIP_BASENAME="$(basename "$ZIP_PATH")"
cp -f "$ZIP_PATH" "$WORK_DIR/01_D2L_Original_Zip/$ZIP_BASENAME"
log_audit "$AUDIT" "copied_zip_to_workspace 01_D2L_Original_Zip/$ZIP_BASENAME"

# Extract ZIP
echo
echo "Extracting ZIP..."
unzip -q "$WORK_DIR/01_D2L_Original_Zip/$ZIP_BASENAME" -d "$WORK_DIR/02_Extracted_Originals"
log_audit "$AUDIT" "extracted_zip_to 02_Extracted_Originals"

mapfile -t ALL_FILES < <(find "$WORK_DIR/02_Extracted_Originals" -type f)
[[ ${#ALL_FILES[@]} -eq 0 ]] && { echo "ERROR: No files found after extraction."; exit 1; }

# Detect index.html (largest index*.htm*)
INDEX_HTML="$(find "$WORK_DIR/02_Extracted_Originals" -maxdepth 6 -type f \( -iname 'index.html' -o -iname 'index.htm' -o -iname 'index*.html' -o -iname 'index*.htm' \) -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
if [[ -n "${INDEX_HTML:-}" ]]; then
  log_audit "$AUDIT" "found_index_html $INDEX_HTML"
else
  log_audit "$AUDIT" "no_index_html_found"
fi

# Reports / outputs
SUMMARY="$WORK_DIR/09_Reports/summary.csv"
QUEUE="$WORK_DIR/09_Reports/marking_queue.csv"
MISSING_ROUGH="$WORK_DIR/09_Reports/missing_rough_work.csv"
MISSING_FINAL="$WORK_DIR/09_Reports/missing_final_copy.csv"
NEEDS_D2L="$WORK_DIR/09_Reports/needs_in_d2l_review.csv"
TEXT_SUMMARY="$WORK_DIR/09_Reports/text_link_extraction_summary.csv"
PDF_FAIL="$WORK_DIR/09_Reports/image_pdf_failures.csv"
NOT_SUBMITTED="$WORK_DIR/09_Reports/not_submitted.csv"
ZEROS="$WORK_DIR/09_Reports/zeros_for_calc.csv"
PROGRESS="$WORK_DIR/09_Reports/marking_progress.csv"
STATS="$WORK_DIR/09_Reports/student_stats.csv"

echo "StudentKey,StudentName,DocCount,ImageCount,TextFile,FinalTextHeuristic,MetaNoteHeuristic" > "$STATS"
echo "StudentKey,StudentName,DocCount,ImageCount,Mode" > "$SUMMARY"
echo "StudentKey,StudentName,FinalPath,RoughPath,TextPath,Mode" > "$QUEUE"
echo "StudentKey,StudentName,Issue,Notes" > "$MISSING_ROUGH"
echo "StudentKey,StudentName,Issue,Notes" > "$MISSING_FINAL"
echo "StudentKey,StudentName,Issue,Notes" > "$NEEDS_D2L"
echo "StudentKey,StudentName,TextFile,URLCount,LikelyFinalText,FinalReasons,MetaNoteDetected,MetaReasons" > "$TEXT_SUMMARY"
echo "StudentKey,StudentName,Reason" > "$PDF_FAIL"
echo "StudentKey,StudentName,Status,Timestamp" > "$PROGRESS"
echo "StudentKey,StudentName,Score" > "$ZEROS"
echo "StudentKey,StudentName" > "$NOT_SUBMITTED"

# State
declare -A student_name
declare -A doc_count img_count
declare -A best_final_path best_final_ext
declare -A textfile_path
declare -A triage_mode  # image-only: FINAL|ROUGH|MIXED|SKIP
declare -A final_heur meta_heur

# Determine PDF capability
DO_PDFS="no"
if [[ "$MAKE_IMAGE_PDFS" == "yes" ]]; then DO_PDFS="yes"; fi
if [[ "$MAKE_IMAGE_PDFS" == "auto" ]] && have_convert; then DO_PDFS="yes"; fi

# ------------------------------------------------------------
# Organize extracted files by student (skip index files)
# ------------------------------------------------------------
echo
echo "Organizing files by student..."

for f in "${ALL_FILES[@]}"; do
  base="$(basename "$f")"
  low="${base,,}"

  # Skip index files
  if [[ "$low" == index.html || "$low" == index.htm || "$low" == index*.html || "$low" == index*.htm ]]; then
    continue
  fi

  parsed="$(parse_student_from_filename "$base")"
  display="${parsed%%|*}"
  key="${parsed##*|}"
  student_name["$key"]="$display"

  ext="${base##*.}"
  [[ "$ext" == "$base" ]] && ext=""

  # MIME fallback
  if [[ -z "$ext" ]]; then
    mt="$(mime_type "$f")"
    if [[ "$mt" == "application/pdf" ]]; then ext="pdf"; fi
    if [[ "$mt" == image/* ]]; then ext="jpg"; fi
  fi

  mkdir -p "$WORK_DIR/03_By_Student_Unsorted/$key"
  mkdir -p "$WORK_DIR/04_By_Student_Images/$key/RAW"
  mkdir -p "$WORK_DIR/05_By_Student_Final_Docs/$key"

  cp -f "$f" "$WORK_DIR/03_By_Student_Unsorted/$key/$base"

  if [[ -z "$ext" ]]; then
    cp -f "$f" "$WORK_DIR/08_Needs_Review/$base" 2>/dev/null || true
    continue
  fi

  if is_image_ext "$ext"; then
    img_count["$key"]=$(( ${img_count["$key"]:-0} + 1 ))
    n=${img_count["$key"]}
    newname="${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_img_$(printf "%02d" "$n").${ext,,}"
    cp -f "$f" "$WORK_DIR/04_By_Student_Images/$key/RAW/$newname"

  elif is_doc_ext "$ext"; then
    doc_count["$key"]=$(( ${doc_count["$key"]:-0} + 1 ))
    cp -f "$f" "$WORK_DIR/05_By_Student_Final_Docs/$key/$base"

    fn=${doc_count["$key"]}
    flatname="${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_final_$(printf "%02d" "$fn").${ext,,}"
    flatpath="$WORK_DIR/07_To_Mark/$flatname"
    cp -f "$f" "$flatpath"

    if [[ -z "${best_final_path["$key"]:-}" ]]; then
      best_final_path["$key"]="$flatpath"
      best_final_ext["$key"]="${ext,,}"
    else
      if is_better_final "$flatpath" "${ext,,}" "${best_final_path["$key"]}" "${best_final_ext["$key"]}"; then
        best_final_path["$key"]="$flatpath"
        best_final_ext["$key"]="${ext,,}"
      fi
    fi
  fi
done

log_audit "$AUDIT" "organized_files_by_student"

# ------------------------------------------------------------
# Extract typed text + links from index.html into per-student files
# Adds heuristics: LIKELY_FINAL_TEXT + META_NOTE_DETECTED
# ------------------------------------------------------------
if [[ -n "${INDEX_HTML:-}" && -f "${INDEX_HTML:-}" ]]; then
  echo
  echo "Extracting typed text + links from index.html into 07_To_Mark ..."
  python3 - "$INDEX_HTML" "$WORK_DIR" "$COURSE_CLEAN" "$ASSIGN_CLEAN" <<'PY'
import sys, re, html
from pathlib import Path

index_html = Path(sys.argv[1])
workdir = Path(sys.argv[2])
course = sys.argv[3]
assign = sys.argv[4]
raw = index_html.read_text(errors="ignore")

def strip_tags(s):
    s = re.sub(r"<script\b.*?</script>", " ", s, flags=re.I|re.S)
    s = re.sub(r"<style\b.*?</style>", " ", s, flags=re.I|re.S)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def safe_name(s):
    s = re.sub(r"\s+", "_", s.strip())
    s = re.sub(r'[\/\\:\*\?"<>\|]', "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s

def to_first_last(last_first):
    if "," in last_first:
        last, first = [x.strip() for x in last_first.split(",", 1)]
        return f"{first} {last}".strip()
    return last_first.strip()

url_re = re.compile(r'https?://[^"\s<>]+', re.I)

def likely_final_text(text_blocks, urls):
    reasons = []
    full = "\n".join(text_blocks).strip()
    full_l = full.lower()

    phrase_patterns = [
        r"\bthis is my final\b",
        r"\bfinal paragraph\b",
        r"\bmy final paragraph\b",
        r"\bfinal copy\b",
        r"\bhere is my final\b",
        r"\bvoici (mon|ma) (texte|paragraphe) final\b",
        r"\bc['’]est (mon|ma) (texte|paragraphe) final\b",
        r"\bparagraphe final\b",
        r"\bversion finale\b",
        r"\bcopie finale\b",
        r"\btexte final\b",
        r"\btravail final\b",
    ]
    if any(re.search(p, full_l) for p in phrase_patterns):
        reasons.append("Contains explicit final-text phrase(s)")

    if len(full) >= 280:
        reasons.append("Substantial length (>= 280 chars)")

    sentence_marks = len(re.findall(r"[.!?]", full))
    if sentence_marks >= 3:
        reasons.append("Multiple sentences detected (>= 3 sentence marks)")

    if urls:
        reasons.append("Contains link(s) (possible final hosted externally)")

    if "Contains explicit final-text phrase(s)" in reasons:
        return True, reasons
    if ("Substantial length (>= 280 chars)" in reasons) and ("Multiple sentences detected (>= 3 sentence marks)" in reasons):
        return True, reasons
    return False, reasons

def meta_note_detected(text_blocks):
    reasons = []
    full = "\n".join(text_blocks).strip()
    full_l = full.lower()

    meta_patterns = [
        # English
        r"\bi'?m sorry\b", r"\bsorry\b", r"\bapolog(?:y|ize|ise)\b",
        r"\bsubmitted (this )?late\b", r"\blate submission\b",
        r"\bwrong (one|assignment|folder|dropbox)\b", r"\bsubmitted it to the wrong\b",
        r"\bi submitted it to the wrong\b",
        # French
        r"\bd[ée]sol[ée]\b", r"\bje suis d[ée]sol[ée]\b",
        r"\ben retard\b", r"\brendu en retard\b", r"\bsoumis en retard\b",
        r"\bmauvais (dossier|devoir|travail|endroit)\b",
        r"\bpas le bon\b", r"\bje l[' ]ai soumis au mauvais\b",
    ]

    hits = [p for p in meta_patterns if re.search(p, full_l)]
    if hits:
        reasons.append("Contains apology/late/wrong-folder type note(s)")
    if 0 < len(full) < 120 and hits:
        reasons.append("Short length suggests logistics note rather than full submission")

    return (len(reasons) > 0), reasons

hdr_re = re.compile(r"<tr[^>]*bgcolor=#AAAAAA[^>]*>.*?<b>(.*?)</b>.*?</tr>", re.I|re.S)
row_re = re.compile(r"<tr[^>]*bgcolor=white[^>]*>(.*?)</tr>", re.I|re.S)

headers = [(m.start(), m.end(), strip_tags(m.group(1))) for m in hdr_re.finditer(raw)]
if not headers:
    sys.exit(0)

headers_with_end = []
for i, (s, e, name) in enumerate(headers):
    end = headers[i+1][0] if i+1 < len(headers) else len(raw)
    headers_with_end.append((e, end, name))

out_dir = workdir / "05_By_Student_Text_Extracted"
to_mark = workdir / "07_To_Mark"
reports = workdir / "09_Reports"
summary_csv = reports / "text_link_extraction_summary.csv"

rows_out = []

for block_start, block_end, last_first in headers_with_end:
    block = raw[block_start:block_end]
    student_fl = to_first_last(last_first)
    student_key = safe_name(student_fl)

    rows = row_re.findall(block)

    all_text = []
    all_urls = set()

    for r in rows:
        c_match = re.split(r"<b>\s*Comments:\s*</b>\s*<br\s*/?>", r, flags=re.I)
        comments_html = c_match[1] if len(c_match) > 1 else ""

        for u in url_re.findall(comments_html):
            all_urls.add(u)

        c_text = strip_tags(comments_html)
        if c_text:
            all_text.append(c_text)

    norm_seen = set()
    dedup_text = []
    for t in all_text:
        keyt = re.sub(r"\s+", " ", t).strip().lower()
        if keyt and keyt not in norm_seen:
            norm_seen.add(keyt)
            dedup_text.append(t)

    if not dedup_text and not all_urls:
        continue

    is_final, final_reasons = likely_final_text(dedup_text, all_urls)
    has_meta, meta_reasons = meta_note_detected(dedup_text)

    out_student_dir = out_dir / student_key
    out_student_dir.mkdir(parents=True, exist_ok=True)

    out_txt = out_student_dir / f"{course}_{assign}_{student_key}_TEXT_LINKS.txt"
    with out_txt.open("w", encoding="utf-8") as f:
        f.write(f"Student (index): {last_first}\n")
        f.write(f"Student (files): {student_fl}\n")
        f.write(f"Source: {index_html.name}\n\n")

        f.write(f"LIKELY_FINAL_TEXT: {'YES' if is_final else 'NO'}\n")
        if final_reasons:
            f.write("FINAL_TEXT_REASONS:\n")
            for r in final_reasons:
                f.write(f"- {r}\n")
        f.write("\n")

        f.write(f"META_NOTE_DETECTED: {'YES' if has_meta else 'NO'}\n")
        if meta_reasons:
            f.write("META_NOTE_REASONS:\n")
            for r in meta_reasons:
                f.write(f"- {r}\n")
        f.write("\n")

        if all_urls:
            f.write("Links found:\n")
            for u in sorted(all_urls):
                f.write(f"- {u}\n")
            f.write("\n")

        f.write("Typed text / comments (deduplicated):\n")
        for t in dedup_text:
            f.write(f"\n---\n{t}\n")

    to_mark_txt = to_mark / out_txt.name
    to_mark_txt.write_text(out_txt.read_text(encoding="utf-8"), encoding="utf-8")

    rows_out.append((
        student_key, student_fl, str(to_mark_txt), len(all_urls),
        "YES" if is_final else "NO", "; ".join(final_reasons),
        "YES" if has_meta else "NO", "; ".join(meta_reasons)
    ))

with summary_csv.open("a", encoding="utf-8") as f:
    for row in rows_out:
        key, name, path, urlc, lf, fr, md, mr = row
        f.write(f'{key},"{name}","{path}",{urlc},{lf},"{fr}",{md},"{mr}"\n')
PY

  log_audit "$AUDIT" "extracted_text_links_from_index_html_structured"
fi

# Map extracted text files from To_Mark folder
for tf in "$WORK_DIR/07_To_Mark/"*"TEXT_LINKS.txt"; do
  [[ -f "$tf" ]] || continue
  key="$(echo "$(basename "$tf")" | sed -nE "s/^${COURSE_CLEAN}_${ASSIGN_CLEAN}_(.+)_TEXT_LINKS\.txt$/\1/p")"
  if [[ -n "$key" ]]; then
    textfile_path["$key"]="$tf"
    [[ -z "${student_name[$key]:-}" ]] && student_name["$key"]="$key"
  fi
done

# Load heuristics flags from TEXT_SUMMARY into arrays (if present)
if [[ -f "$TEXT_SUMMARY" ]]; then
  # Skip header
  tail -n +2 "$TEXT_SUMMARY" | while IFS= read -r line; do
    # crude parse: first field is StudentKey, fifth is LikelyFinalText, seventh is MetaNoteDetected
    # safe because StudentKey has no commas
    key="$(echo "$line" | cut -d',' -f1)"
    lf="$(echo "$line" | cut -d',' -f5)"
    md="$(echo "$line" | cut -d',' -f7)"
    [[ -n "$key" ]] && final_heur["$key"]="$lf" && meta_heur["$key"]="$md"
  done
fi

# ------------------------------------------------------------
# TRIAGE PROMPTS: ONLY image-only students (no doc finals)
# ------------------------------------------------------------
echo
echo "============================================================"
echo " TRIAGE (image-only students only)"
echo "============================================================"
echo "Default is FINAL(images)."
echo

mapfile -t STUDENTS < <(for k in "${!student_name[@]}"; do
  echo "${student_name[$k]}|$k"
done | sort)

for entry in "${STUDENTS[@]}"; do
  display="${entry%%|*}"
  key="${entry##*|}"
  docs=${doc_count["$key"]:-0}
  imgs=${img_count["$key"]:-0}

  if [[ "$docs" -eq 0 && "$imgs" -gt 0 ]]; then
    echo
    echo "Student: $display  (images only: $imgs)"
    echo "Options: [Enter]=FINAL  R=ROUGH(missing final)  M=MIXED  S=SKIP"
    read -rp "Choice: " ans
    ans="${ans:-}"

    case "${ans^^}" in
      "") triage_mode["$key"]="FINAL" ;;
      R)  triage_mode["$key"]="ROUGH" ;;
      M)  triage_mode["$key"]="MIXED" ;;
      S)  triage_mode["$key"]="SKIP" ;;
      *)  triage_mode["$key"]="FINAL" ;;
    esac

    if [[ "${triage_mode[$key]}" == "MIXED" ]]; then
      mkdir -p "$WORK_DIR/04_By_Student_Images/$key/FINAL" "$WORK_DIR/04_By_Student_Images/$key/ROUGH"
      cp -f "$WORK_DIR/04_By_Student_Images/$key/RAW/"* "$WORK_DIR/04_By_Student_Images/$key/ROUGH/" 2>/dev/null || true
      echo "MIXED: copied all images into ROUGH/ by default. Move FINAL pages into FINAL/ now."
      xdg-open "$WORK_DIR/04_By_Student_Images/$key" >/dev/null 2>&1 || true
      read -rp "Press ENTER when done sorting FINAL vs ROUGH for $display: " _
    fi
  fi
done

log_audit "$AUDIT" "completed_image_only_triage"

# ------------------------------------------------------------
# Build packets + queue + action lists + stats table
# ------------------------------------------------------------
TMP_QUEUE="$WORK_DIR/09_Reports/.queue.tmp"
: > "$TMP_QUEUE"

for entry in "${STUDENTS[@]}"; do
  display="${entry%%|*}"
  key="${entry##*|}"

  docs=${doc_count["$key"]:-0}
  imgs=${img_count["$key"]:-0}
  textp="${textfile_path["$key"]:-}"

  mode="AUTO"
  final=""
  rough=""

  if [[ "$docs" -gt 0 ]]; then
    mode="DOC_FINAL"
    final="${best_final_path["$key"]:-}"

    if [[ "$imgs" -gt 0 && ( "$MAKE_IMAGE_PDFS" == "yes" || ( "$MAKE_IMAGE_PDFS" == "auto" && "$(have_convert && echo yes || echo no)" == "yes" ) ) ]]; then
      if have_convert; then
        outpdf="$WORK_DIR/06_Image_PDF_Packets/${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_ROUGH_images.pdf"
        if make_pdf_from_images "$WORK_DIR/04_By_Student_Images/$key/RAW" "$outpdf"; then
          rough="$outpdf"
        else
          echo "$key,\"$display\",rough_pdf_failed" >> "$PDF_FAIL"
        fi
      fi
    fi

    if [[ "$imgs" -eq 0 ]]; then
      echo "$key,\"$display\",missing_rough,\"No images found (rough work missing)\"" >> "$MISSING_ROUGH"
    fi

  else
    if [[ "$imgs" -gt 0 ]]; then
      mode="IMAGE_ONLY"
      choice="${triage_mode["$key"]:-FINAL}"

      if [[ "$choice" == "SKIP" ]]; then
        echo "$key,\"$display\",$docs,$imgs,\"$textp\",\"${final_heur[$key]:-}\",\"${meta_heur[$key]:-}\"" >> "$STATS"
        echo "$key,\"$display\",${docs},${imgs},\"SKIP\"" >> "$SUMMARY"
        echo "$key,\"$display\",\"\",\"\",\"$textp\",\"SKIP\"" >> "$TMP_QUEUE"
        continue
      fi

      if [[ "$choice" == "ROUGH" ]]; then
        echo "$key,\"$display\",missing_final,\"Images triaged as rough; final missing\"" >> "$MISSING_FINAL"
        rough="$WORK_DIR/04_By_Student_Images/$key/RAW"
        final=""

      elif [[ "$choice" == "FINAL" ]]; then
        if have_convert && [[ "$MAKE_IMAGE_PDFS" != "no" ]]; then
          outpdf="$WORK_DIR/06_Image_PDF_Packets/${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_FINAL_images.pdf"
          if make_pdf_from_images "$WORK_DIR/04_By_Student_Images/$key/RAW" "$outpdf"; then
            final="$outpdf"
            cp -f "$outpdf" "$WORK_DIR/07_To_Mark/$(basename "$outpdf")" 2>/dev/null || true
          else
            echo "$key,\"$display\",final_pdf_failed" >> "$PDF_FAIL"
            final="$WORK_DIR/04_By_Student_Images/$key/RAW"
          fi
        else
          final="$WORK_DIR/04_By_Student_Images/$key/RAW"
        fi

      elif [[ "$choice" == "MIXED" ]]; then
        if have_convert && [[ "$MAKE_IMAGE_PDFS" != "no" ]]; then
          out_final="$WORK_DIR/06_Image_PDF_Packets/${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_FINAL_images.pdf"
          out_rough="$WORK_DIR/06_Image_PDF_Packets/${COURSE_CLEAN}_${ASSIGN_CLEAN}_${key}_ROUGH_images.pdf"

          if make_pdf_from_images "$WORK_DIR/04_By_Student_Images/$key/FINAL" "$out_final"; then
            final="$out_final"
            cp -f "$out_final" "$WORK_DIR/07_To_Mark/$(basename "$out_final")" 2>/dev/null || true
          else
            echo "$key,\"$display\",mixed_final_pdf_failed" >> "$PDF_FAIL"
            final="$WORK_DIR/04_By_Student_Images/$key/FINAL"
          fi

          if make_pdf_from_images "$WORK_DIR/04_By_Student_Images/$key/ROUGH" "$out_rough"; then
            rough="$out_rough"
          else
            rough="$WORK_DIR/04_By_Student_Images/$key/ROUGH"
          fi
        else
          final="$WORK_DIR/04_By_Student_Images/$key/FINAL"
          rough="$WORK_DIR/04_By_Student_Images/$key/ROUGH"
        fi
      fi

    else
      if [[ -n "$textp" && -f "$textp" ]]; then
        mode="TEXT_ONLY"
        final="$textp"
      else
        mode="NEEDS_D2L"
        echo "$key,\"$display\",needs_in_d2l_review,\"No downloadable files; likely submission box / native media / link-only\"" >> "$NEEDS_D2L"
      fi
    fi
  fi

  echo "$key,\"$display\",$docs,$imgs,\"$textp\",\"${final_heur[$key]:-}\",\"${meta_heur[$key]:-}\"" >> "$STATS"
  echo "$key,\"$display\",${docs},${imgs},\"$mode\"" >> "$SUMMARY"
  echo "$key,\"$display\",\"$final\",\"$rough\",\"$textp\",\"$mode\"" >> "$TMP_QUEUE"
done

# Write sorted queue
echo "StudentKey,StudentName,FinalPath,RoughPath,TextPath,Mode" > "$QUEUE"
sort -t, -k2,2 "$TMP_QUEUE" >> "$QUEUE"
rm -f "$TMP_QUEUE"
log_audit "$AUDIT" "generated_queue_and_reports"

# ------------------------------------------------------------
# Class list cross-check → not submitted + zeros file
# ------------------------------------------------------------
# You can export classlist from D2L with Last/First/Email; exporting classlist data to CSV is supported in Brightspace. 
# Bulk download only downloads folders for students who submitted, so this comparison finds non-submitters. [1](https://wiki.millersville.edu/spaces/d2ldocs/pages/122754292/Downloading+student+submissions+from+assignments)
if [[ -n "${CLASSLIST_PATH:-}" && -f "${CLASSLIST_PATH:-}" ]]; then
  echo
  echo "Cross-checking against class list CSV..."
  python3 - "$CLASSLIST_PATH" "$WORK_DIR" <<'PY'
import csv, sys, re
from pathlib import Path

classlist = Path(sys.argv[1])
workdir = Path(sys.argv[2])
reports = workdir / "09_Reports"
not_sub = reports / "not_submitted.csv"
zeros = reports / "zeros_for_calc.csv"

# Load submitted keys from summary.csv (created by bash)
submitted = set()
summary = reports / "summary.csv"
if summary.exists():
    with summary.open(newline='', encoding='utf-8', errors='ignore') as f:
        r = csv.DictReader(f)
        for row in r:
            k = (row.get("StudentKey") or "").strip()
            if k:
                submitted.add(k)

def safe_name(s):
    s = re.sub(r"\s+", "_", s.strip())
    s = re.sub(r'[\/\\:\*\?"<>\|]', "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s

def find_field(headers, candidates):
    hmap = {h.strip().lower(): h for h in headers}
    for c in candidates:
        if c in hmap:
            return hmap[c]
    return None

# Read class list and derive StudentKey as "First Last"
rows = []
with classlist.open(newline='', encoding='utf-8', errors='ignore') as f:
    r = csv.DictReader(f)
    headers = r.fieldnames or []
    fn_field = find_field(headers, ["first name","firstname","first"])
    ln_field = find_field(headers, ["last name","lastname","last","surname","family name"])
    name_field = find_field(headers, ["name","student","learner"])

    for row in r:
        if fn_field and ln_field:
            first = (row.get(fn_field) or "").strip()
            last = (row.get(ln_field) or "").strip()
            if first and last:
                display = f"{first} {last}"
            else:
                display = (row.get(name_field) or "").strip() if name_field else ""
        else:
            display = (row.get(name_field) or "").strip() if name_field else ""

        if not display:
            continue

        key = safe_name(display)
        rows.append((key, display))

# Write not_submitted + zeros_for_calc
with not_sub.open("w", newline='', encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["StudentKey","StudentName"])
    for key, display in rows:
        if key not in submitted:
            w.writerow([key, display])

with zeros.open("w", newline='', encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["StudentKey","StudentName","Score"])
    for key, display in rows:
        if key not in submitted:
            w.writerow([key, display, 0])
PY
  log_audit "$AUDIT" "classlist_crosscheck_completed"
else
  echo
  echo "No class list provided (or file not found). Skipping non-submitter report."
fi

# ------------------------------------------------------------
# Improved launcher (CSV-safe, shows counts + flags, skip SKIP, progress)
# ------------------------------------------------------------
LAUNCHER="$WORK_DIR/open_next_to_mark.sh"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

QUEUE_FILE="\$(dirname "\$0")/09_Reports/marking_queue.csv"
STATS_FILE="\$(dirname "\$0")/09_Reports/student_stats.csv"
PROGRESS_FILE="\$(dirname "\$0")/09_Reports/marking_progress.csv"
PROMPT_DONE="${PROMPT_MARK_DONE}"

python3 - "\$QUEUE_FILE" "\$STATS_FILE" "\$PROGRESS_FILE" "\$PROMPT_DONE" <<'PY'
import csv, sys, subprocess
from pathlib import Path
from datetime import datetime

queue = Path(sys.argv[1])
statsf = Path(sys.argv[2])
progressf = Path(sys.argv[3])
prompt_done = sys.argv[4].strip().lower() == "yes"

def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def load_csv(p):
    if not p.exists():
        return []
    with p.open(newline='', encoding='utf-8', errors='ignore') as f:
        return list(csv.DictReader(f))

rows = load_csv(queue)
stats_rows = load_csv(statsf)
prog_rows = load_csv(progressf)

# build stats map
stats = {}
for r in stats_rows:
    k = (r.get("StudentKey") or "").strip()
    if k:
        stats[k] = r

# progress map
progress = {}
for r in prog_rows:
    k = (r.get("StudentKey") or "").strip()
    if k:
        progress[k] = r.get("Status","").strip().upper()

# filter: skip SKIP always, and hide DONE by default
pending = []
for r in rows:
    key = (r.get("StudentKey") or "").strip()
    name = (r.get("StudentName") or "").strip()
    mode = (r.get("Mode") or "").strip()
    if not key:
        continue
    if mode.upper() == "SKIP":
        continue
    if progress.get(key,"") == "DONE":
        continue
    pending.append(r)

def open_path(p):
    if not p:
        return
    path = Path(p)
    if not path.exists():
        print(f"⚠️ Not found: {path}")
        return
    subprocess.Popen(["xdg-open", str(path)],
                     stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)

def write_progress(key, name, status):
    # append row
    with progressf.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([key, name, status, now()])

print("============================================================")
print(" Marking Queue (Pending)")
print("============================================================")
print("ENTER = open next pending | number = open specific | A = show all")
choice = input("Choice: ").strip()

use_rows = pending
if choice.upper() == "A":
    use_rows = rows

# Build menu
items = []
for i, r in enumerate(use_rows, start=1):
    key = (r.get("StudentKey") or "").strip()
    name = (r.get("StudentName") or "").strip()
    mode = (r.get("Mode") or "").strip()
    final = (r.get("FinalPath") or "").strip()
    rough = (r.get("RoughPath") or "").strip()
    textp = (r.get("TextPath") or "").strip()

    st = stats.get(key, {})
    docs = (st.get("DocCount") or "0").strip()
    imgs = (st.get("ImageCount") or "0").strip()
    has_text = "Y" if (st.get("TextFile") or "").strip() else "N"
    finh = (st.get("FinalTextHeuristic") or "").strip()
    metah = (st.get("MetaNoteHeuristic") or "").strip()
    finh = finh if finh else "-"
    metah = metah if metah else "-"

    status_tag = progress.get(key,"")
    if not status_tag:
        status_tag = "PENDING"
    line = f"[{i}] {name} | docs:{docs} imgs:{imgs} text:{has_text} | final:{finh} meta:{metah} | {mode} | {status_tag}"
    print(line)
    items.append((key, name, final, rough, textp, mode))

if not items:
    print("No items to open.")
    sys.exit(0)

# Determine selection
if choice == "":
    idx = 0  # next pending
else:
    try:
        idx = int(choice) - 1
    except ValueError:
        idx = 0

if idx < 0 or idx >= len(items):
    print("Invalid selection.")
    sys.exit(1)

key, name, final, rough, textp, mode = items[idx]

print(f"\nOpening for: {name}")
open_path(final)
open_path(rough)
open_path(textp)

write_progress(key, name, "OPENED")

if prompt_done:
    ans = input("Mark this student DONE now? (y/n, ENTER=no): ").strip().lower()
    if ans == "y":
        write_progress(key, name, "DONE")
        print("Marked DONE.")
print("Done.")
PY
EOF

chmod +x "$LAUNCHER"
log_audit "$AUDIT" "created_launcher open_next_to_mark.sh"

echo
echo "============================================================"
echo "DONE ✅ Workspace created"
echo "============================================================"
echo "Workspace: $WORK_DIR"
echo "To mark:    $WORK_DIR/07_To_Mark"
echo "Queue:      $WORK_DIR/09_Reports/marking_queue.csv"
echo "Launcher:   $WORK_DIR/open_next_to_mark.sh"
echo
echo "Reports:"
echo " - Student stats:          $WORK_DIR/09_Reports/student_stats.csv"
echo " - Missing rough:          $WORK_DIR/09_Reports/missing_rough_work.csv"
echo " - Missing final:          $WORK_DIR/09_Reports/missing_final_copy.csv"
echo " - Needs D2L review:       $WORK_DIR/09_Reports/needs_in_d2l_review.csv"
echo " - Text heuristics summary $WORK_DIR/09_Reports/text_link_extraction_summary.csv"
echo " - Progress log:           $WORK_DIR/09_Reports/marking_progress.csv"
echo
if [[ -n "${CLASSLIST_PATH:-}" && -f "${CLASSLIST_PATH:-}" ]]; then
  echo "Class list cross-check:"
  echo " - Not submitted:          $WORK_DIR/09_Reports/not_submitted.csv"
  echo " - Zeros for Calc:         $WORK_DIR/09_Reports/zeros_for_calc.csv"
fi
echo
echo "Run launcher:"
echo "  $WORK_DIR/open_next_to_mark.sh"
echo
# D2L Marking Workspace Builder (Local / Linux Mint)
# ============================================================
