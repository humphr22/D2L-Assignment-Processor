#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Local-only D2L marking workspace generator (Linux Mint)
# ------------------------------------------------------------
# Purpose:
# - Build a consistent marking workspace from a D2L bulk-download ZIP
# - Group submissions by student
# - Separate probable rough-work images vs probable final documents
# - Optional: create per-student rough-work PDF packets (ImageMagick)
#
# Safe-by-design:
# - Never deletes original zip or extracted originals
# - Copies files into organized folders
# ------------------------------------------------------------

# ----------- USER-EDITABLE DEFAULTS -----------
BASE_DIR="$HOME/Teaching_Marking"      # Change if you want a different root
MAKE_ROUGH_PDFS="auto"                # "auto" (if convert exists), "yes", or "no"
# ---------------------------------------------

# ---- Helpers ----
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Keep accents; just replace risky path characters
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
  local file="$1"; shift
  echo "\"$(timestamp)\",\"$*\"" >> "$file"
}

# Attempt to extract "Last_First" from common D2L filename patterns.
# Falls back to "UnknownStudent".
guess_student_key() {
  local fn="$1"
  local base="${fn##*/}"

  # Common pattern example:
  # "12345-67890 - Lastname, Firstname - originalfilename.ext"
  # We'll try to catch "Lastname, Firstname"
  if echo "$base" | grep -qE ' - [^,]+, [^-]+ - '; then
    local name_part
    name_part="$(echo "$base" | sed -nE 's/^.* - ([^,]+), ([^-]+) - .*$/\1_\2/p')"
    name_part="$(echo "$name_part" | sed 's/[[:space:]]\+/_/g' | sed 's/_\+/_/g' | sed 's/^_//' | sed 's/_$//')"
    if [[ -n "$name_part" ]]; then
      echo "$name_part"
      return 0
    fi
  fi

  # Alternate: sometimes "Lastname_Firstname" already appears
  if echo "$base" | grep -qE '[A-Za-z]+_[A-Za-z]+'; then
    local cand
    cand="$(echo "$base" | grep -oE '[A-Za-z]+_[A-Za-z]+' | head -n 1)"
    [[ -n "$cand" ]] && { echo "$cand"; return 0; }
  fi

  echo "UnknownStudent"
}

is_image() {
  local ext="${1,,}"
  case "$ext" in
    jpg|jpeg|png|webp|heic|heif) return 0 ;;
    *) return 1 ;;
  esac
}

is_doc() {
  local ext="${1,,}"
  case "$ext" in
    pdf|doc|docx|odt|rtf|txt) return 0 ;;
    *) return 1 ;;
  esac
}

have_convert() {
  command -v convert >/dev/null 2>&1
}

# ---- Start ----
echo "============================================================"
echo " D2L Marking Workspace Builder (Local / Linux Mint)"
echo "============================================================"
echo "Base directory: $BASE_DIR"
echo

mkdir -p "$BASE_DIR"

read -rp "Course code (e.g., FSF1D1): " COURSE
read -rp "Assignment name (e.g., Tâche Finale Unité 3): " ASSIGNMENT
read -rp "Collection date (YYYY-MM-DD): " DATE_STR

COURSE_CLEAN="$(safe_name "$COURSE")"
ASSIGN_CLEAN="$(safe_name "$ASSIGNMENT")"

WORK_NAME="${DATE_STR}_${ASSIGN_CLEAN}"
WORK_DIR="$BASE_DIR/$COURSE_CLEAN/$WORK_NAME"

# If folder exists, create a safe unique suffix
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

# Prompt for ZIP
echo
read -rp "Path to D2L downloaded ZIP file: " ZIP_PATH
ZIP_PATH="$(strip_quotes "$ZIP_PATH")"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ERROR: ZIP file not found:"
  echo "  $ZIP_PATH"
  exit 1
fi

# Folders
mkdir -p "$WORK_DIR"/{01_D2L_Original_Zip,02_Extracted_Originals,03_By_Student_Unsorted,04_By_Student_Rough_Images,05_By_Student_Final_Docs,06_Rough_PDF_Packets,07_To_Mark,08_Needs_Review,09_Reports}

AUDIT="$WORK_DIR/audit_log.csv"
echo "\"Timestamp\",\"Action\"" > "$AUDIT"
log_audit "$AUDIT" "created_workspace $WORK_DIR"
log_audit "$AUDIT" "zip_source $ZIP_PATH"

# Copy ZIP into workspace
ZIP_BASENAME="$(basename "$ZIP_PATH")"
cp -f "$ZIP_PATH" "$WORK_DIR/01_D2L_Original_Zip/$ZIP_BASENAME"
log_audit "$AUDIT" "copied_zip_to_workspace 01_D2L_Original_Zip/$ZIP_BASENAME"

# Extract ZIP
echo
echo "Extracting ZIP..."
unzip -q "$WORK_DIR/01_D2L_Original_Zip/$ZIP_BASENAME" -d "$WORK_DIR/02_Extracted_Originals"
log_audit "$AUDIT" "extracted_zip_to 02_Extracted_Originals"

# Build list of files
mapfile -t ALL_FILES < <(find "$WORK_DIR/02_Extracted_Originals" -type f)

if [[ ${#ALL_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No files found after extraction."
  exit 1
fi

# Reports
SUMMARY="$WORK_DIR/09_Reports/process_evidence_summary.csv"
AMBIG="$WORK_DIR/09_Reports/ambiguous_files.csv"
echo "StudentKey,RoughImageCount,FinalDocCount,OtherCount,Status" > "$SUMMARY"
echo "OriginalPath,StudentKey,Reason" > "$AMBIG"

# Per-student counters (bash associative arrays)
declare -A rough_count final_count other_count

echo
echo "Organizing files by student..."
for f in "${ALL_FILES[@]}"; do
  base="$(basename "$f")"
  ext="${base##*.}"
  student="$(guess_student_key "$base")"
  student_clean="$(safe_name "$student")"

  # Ensure student folders
  mkdir -p "$WORK_DIR/03_By_Student_Unsorted/$student_clean"
  mkdir -p "$WORK_DIR/04_By_Student_Rough_Images/$student_clean"
  mkdir -p "$WORK_DIR/05_By_Student_Final_Docs/$student_clean"

  # Always copy into unsorted bucket
  cp -f "$f" "$WORK_DIR/03_By_Student_Unsorted/$student_clean/$base"

  if [[ "$ext" == "$base" ]]; then
    # no extension
    other_count["$student_clean"]=$(( ${other_count["$student_clean"]:-0} + 1 ))
    echo "\"$f\",\"$student_clean\",\"no_extension\"" >> "$AMBIG"
    cp -f "$f" "$WORK_DIR/08_Needs_Review/$base" 2>/dev/null || true
    continue
  fi

  if is_image "$ext"; then
    rough_count["$student_clean"]=$(( ${rough_count["$student_clean"]:-0} + 1 ))
    # Rename images to a consistent rough_XX.ext pattern
    n=${rough_count["$student_clean"]}
    newname="${COURSE_CLEAN}_${ASSIGN_CLEAN}_${student_clean}_rough_$(printf "%02d" "$n").${ext,,}"
    cp -f "$f" "$WORK_DIR/04_By_Student_Rough_Images/$student_clean/$newname"
  elif is_doc "$ext"; then
    final_count["$student_clean"]=$(( ${final_count["$student_clean"]:-0} + 1 ))
    # Keep original base but also stage into To_Mark for fast marking
    cp -f "$f" "$WORK_DIR/05_By_Student_Final_Docs/$student_clean/$base"
    # Also copy into a flat To_Mark folder with a stable name
    newname="${COURSE_CLEAN}_${ASSIGN_CLEAN}_${student_clean}_final_${final_count["$student_clean"]}.${ext,,}"
    cp -f "$f" "$WORK_DIR/07_To_Mark/$newname"
  else
    other_count["$student_clean"]=$(( ${other_count["$student_clean"]:-0} + 1 ))
    echo "\"$f\",\"$student_clean\",\"unknown_extension_$ext\"" >> "$AMBIG"
    cp -f "$f" "$WORK_DIR/08_Needs_Review/$base" 2>/dev/null || true
  fi
done

log_audit "$AUDIT" "organized_files_by_student"

# Optional: Generate rough-work PDFs
DO_PDFS="no"
if [[ "$MAKE_ROUGH_PDFS" == "yes" ]]; then
  DO_PDFS="yes"
elif [[ "$MAKE_ROUGH_PDFS" == "auto" ]] && have_convert; then
  DO_PDFS="yes"
fi

if [[ "$DO_PDFS" == "yes" ]]; then
  echo
  echo "Creating rough-work PDF packets (ImageMagick convert)..."
  for student_dir in "$WORK_DIR/04_By_Student_Rough_Images"/*; do
    [[ -d "$student_dir" ]] || continue
    student="$(basename "$student_dir")"
    shopt -s nullglob
    imgs=( "$student_dir"/*.{jpg,jpeg,png,webp,heic,heif,JPG,JPEG,PNG,WEBP,HEIC,HEIF} )
    shopt -u nullglob
    if [[ ${#imgs[@]} -gt 0 ]]; then
      outpdf="$WORK_DIR/06_Rough_PDF_Packets/${COURSE_CLEAN}_${ASSIGN_CLEAN}_${student}_rough_packet.pdf"
      # convert can choke on some HEIC depending on build; if it fails, it will be logged
      if convert "${imgs[@]}" "$outpdf" 2>/dev/null; then
        :
      else
        echo "\"$student\",\"convert_failed\"" >> "$WORK_DIR/09_Reports/rough_pdf_failures.csv"
      fi
    fi
  done
  log_audit "$AUDIT" "generated_rough_pdf_packets"
else
  echo
  echo "Skipping rough-work PDF packets (set MAKE_ROUGH_PDFS=yes or install ImageMagick)."
fi

# Build summary report
echo
echo "Writing summary report..."
for student in "${!rough_count[@]}" "${!final_count[@]}" "${!other_count[@]}"; do :; done
# Collect unique students
declare -A seen
for k in "${!rough_count[@]}"; do seen["$k"]=1; done
for k in "${!final_count[@]}"; do seen["$k"]=1; done
for k in "${!other_count[@]}"; do seen["$k"]=1; done

for student in "${!seen[@]}"; do
  r=${rough_count["$student"]:-0}
  d=${final_count["$student"]:-0}
  o=${other_count["$student"]:-0}

  status="ready_to_mark"
  if [[ "$d" -eq 0 ]]; then status="missing_final_doc"; fi
  if [[ "$r" -eq 0 ]]; then status="${status};missing_rough_images"; fi
  if [[ "$student" == "UnknownStudent" ]]; then status="${status};unknown_student_parse"; fi

  echo "$student,$r,$d,$o,$status" >> "$SUMMARY"
done

log_audit "$AUDIT" "wrote_reports 09_Reports"

echo
echo "============================================================"
echo "DONE ✅ Marking workspace created"
echo "============================================================"
echo "Workspace:"
echo "  $WORK_DIR"
echo
echo "Fast marking folder (flattened finals):"
echo "  $WORK_DIR/07_To_Mark"
echo
echo "Rough images by student:"
echo "  $WORK_DIR/04_By_Student_Rough_Images"
echo
echo "Reports:"
echo "  $WORK_DIR/09_Reports/process_evidence_summary.csv"
echo "  $WORK_DIR/09_Reports/ambiguous_files.csv"
echo
echo "Audit log:"
echo "  $WORK_DIR/audit_log.csv"
echo
``
