#!/usr/bin/env python3
import os
import re
import sys
import csv
import shutil
import zipfile
import html
import subprocess
from pathlib import Path

# Optional: Try importing Pillow for reliable image-to-PDF conversion
try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif'}
DOC_EXTS = {'.pdf', '.doc', '.docx', '.odt', '.rtf', '.txt'}

def safe_name(name):
    """Clean string for safe folder/filename usage."""
    s = re.sub(r'\s+', '_', str(name).strip())
    s = re.sub(r'[\/\\:\*\?"<>\|]', '_', s)
    s = re.sub(r'_+', '_', s)
    return s.strip('_')

def parse_student_name(filename):
    """Extract student name from D2L submission filename pattern."""
    # Pattern: 123456-78901 - Student Name - Date - OriginalFileName.ext
    match = re.match(r'^\d+-\d+\s*-\s*(.+?)\s*-\s*(?:janv?|févr?|fevr?|mars|avr|avril|mai|juin|juil?|août|aout|sept?|oct|nov|déc|dec|[a-zA-Z]{3,4})\.?\b', filename, re.I)
    if match:
        raw_name = match.group(1).strip()
        # Convert "Lastname, Firstname" to "Firstname Lastname" if comma present
        if ',' in raw_name:
            parts = raw_name.split(',', 1)
            raw_name = f"{parts[1].strip()} {parts[0].strip()}"
        return raw_name, safe_name(raw_name)
    return "Unknown Student", "Unknown_Student"

def extract_typed_text_from_index(index_path):
    """Extract D2L submission comments and typed text per student."""
    if not index_path.exists():
        return {}

    content = index_path.read_text(encoding='utf-8', errors='ignore')
    
    # Split blocks by student table headers
    hdr_re = re.compile(r'<tr[^>]*bgcolor=#AAAAAA[^>]*>.*?<b>(.*?)</b>.*?</tr>', re.I | re.S)
    row_re = re.compile(r'<tr[^>]*bgcolor=white[^>]*>(.*?)</tr>', re.I | re.S)
    
    headers = list(hdr_re.finditer(content))
    extracted = {}

    for i, h in enumerate(headers):
        start = h.end()
        end = headers[i+1].start() if i+1 < len(headers) else len(content)
        raw_student = h.group(1).strip()
        
        # Format name
        if ',' in raw_student:
            parts = raw_student.split(',', 1)
            display_name = f"{parts[1].strip()} {parts[0].strip()}"
        else:
            display_name = raw_student
            
        key = safe_name(display_name)
        block = content[start:end]
        
        comments = []
        for r in row_re.findall(block):
            c_match = re.split(r'<b>\s*Comments:\s*</b>\s*<br\s*/?>', r, flags=re.I)
            if len(c_match) > 1:
                clean_c = re.sub(r'<script\b.*?</script>', ' ', c_match[1], flags=re.I|re.S)
                clean_c = re.sub(r'<style\b.*?</style>', ' ', clean_c, flags=re.I|re.S)
                clean_c = re.sub(r'<[^>]+>', ' ', clean_c)
                clean_c = html.unescape(clean_c)
                clean_c = re.sub(r'\s+', ' ', clean_c).strip()
                if clean_c:
                    comments.append(clean_c)
                    
        if comments:
            extracted[key] = {
                'display': display_name,
                'text': "\n\n---\n\n".join(dict.fromkeys(comments)) # Deduplicate
            }

    return extracted

def compile_images_to_pdf(image_paths, output_pdf_path):
    """Combine image files into a single PDF packet."""
    if not image_paths:
        return False
    
    # Attempt PIL method
    if HAS_PIL:
        try:
            images = []
            for img_p in image_paths:
                im = Image.open(img_p)
                if im.mode != 'RGB':
                    im = im.convert('RGB')
                images.append(im)
            if images:
                images[0].save(output_pdf_path, save_all=True, append_images=images[1:])
                return True
        except Exception:
            pass

    # Fallback to system 'convert' (ImageMagick)
    if shutil.which('convert'):
        try:
            cmd = ['convert'] + [str(p) for p in image_paths] + [str(output_pdf_path)]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            pass

    return False

def generate_launcher_script(workspace_dir):
    """Generate a clean mark_next.py launcher script in the workspace."""
    launcher_content = '''#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path(__file__).parent.resolve()
STUDENTS_DIR = WORKSPACE / "Students"
PROGRESS_FILE = WORKSPACE / "Reports" / "progress.json"

def load_progress():
    if PROGRESS_FILE.exists():
        with open(PROGRESS_FILE, 'r') as f:
            return json.load(f)
    return {}

def save_progress(data):
    PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(PROGRESS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def main():
    student_dirs = sorted([d for d in STUDENTS_DIR.iterdir() if d.is_dir()])
    if not student_dirs:
        print("No student folders found!")
        sys.exit(1)

    progress = load_progress()

    while True:
        pending = [d for d in student_dirs if progress.get(d.name) != "DONE"]
        
        print("\\n" + "="*50)
        print(f" MARKING QUEUE ({len(pending)} / {len(student_dirs)} remaining)")
        print("="*50)
        
        for i, d in enumerate(student_dirs, 1):
            status = progress.get(d.name, "PENDING")
            flag = "[X]" if status == "DONE" else "[ ]"
            print(f"{i:2d}. {flag} {d.name.replace('_', ' ')}")

        print("\\nOptions:")
        print(" - Press [ENTER] to open next pending student")
        print(" - Enter student number to open specific student")
        print(" - Enter 'q' to quit")
        
        choice = input("\\nChoice: ").strip().lower()
        if choice == 'q':
            break

        target_dir = None
        if choice == "":
            if pending:
                target_dir = pending[0]
            else:
                print("All students marked DONE!")
                break
        else:
            try:
                idx = int(choice) - 1
                if 0 <= idx < len(student_dirs):
                    target_dir = student_dirs[idx]
            except ValueError:
                pass

        if not target_dir:
            print("Invalid choice.")
            continue

        print(f"\\nOpening files for: {target_dir.name.replace('_', ' ')}")
        
        # Open student directory in Linux file manager
        subprocess.Popen(["xdg-open", str(target_dir)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Open document/text files automatically if present
        for f in target_dir.iterdir():
            if f.suffix.lower() in ['.pdf', '.txt', '.docx', '.odt']:
                subprocess.Popen(["xdg-open", str(f)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        done = input(f"Mark {target_dir.name.replace('_', ' ')} as DONE? (y/n, ENTER=no): ").strip().lower()
        if done == 'y':
            progress[target_dir.name] = "DONE"
            save_progress(progress)

if __name__ == "__main__":
    main()
'''
    launcher_path = workspace_dir / "mark_next.py"
    launcher_path.write_text(launcher_content, encoding='utf-8')
    os.chmod(launcher_path, 0o755)

def main():
    print("=" * 60)
    print(" D2L Workspace Setup (Simplified & Unified)")
    print("=" * 60)

    base_dir = Path.home() / "Teaching_Marking"
    course = input("Course Code (e.g., FSF1D1): ").strip()
    assignment = input("Assignment Name (e.g., U1_Tache_Finale): ").strip()
    
    zip_input = input("Path to D2L ZIP file: ").strip().strip("'\"")
    zip_path = Path(zip_input)

    if not zip_path.is_file():
        print(f"ERROR: ZIP file not found at '{zip_path}'")
        sys.exit(1)

    classlist_input = input("Optional Classlist CSV/XLSX path (ENTER to skip): ").strip().strip("'\"")
    
    # Create main workspace
    work_dir = base_dir / safe_name(course) / safe_name(assignment)
    students_dir = work_dir / "Students"
    reports_dir = work_dir / "Reports"
    temp_extract = work_dir / "_temp_extract"

    if work_dir.exists():
        resp = input(f"Workspace {work_dir} exists. Overwrite/re-process? (y/n): ").strip().lower()
        if resp != 'y':
            print("Cancelled.")
            sys.exit(0)
        shutil.rmtree(work_dir)

    students_dir.mkdir(parents=True, exist_ok=True)
    reports_dir.mkdir(parents=True, exist_ok=True)

    print("\nExtracting D2L ZIP file...")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(temp_extract)

    # Search for index.html
    index_files = list(temp_extract.glob("**/index*.htm*"))
    typed_comments = {}
    if index_files:
        # Get largest index file
        index_path = max(index_files, key=lambda p: p.stat().st_size)
        typed_comments = extract_typed_text_from_index(index_path)

    # Process all student submission files
    all_extracted_files = [p for p in temp_extract.glob("**/*") if p.is_file()]
    students_found = set()

    print("Organizing files into student folders...")
    
    for file_path in all_extracted_files:
        filename = file_path.name
        if filename.lower().startswith("index") and filename.lower().endswith(('.html', '.htm')):
            continue

        display_name, key = parse_student_name(filename)
        students_found.add(key)

        student_folder = students_dir / key
        student_folder.mkdir(exist_ok=True)

        # Move/Copy file into student folder
        ext = file_path.suffix.lower()
        clean_filename = f"{key}_{filename}" if not filename.startswith(key) else filename
        shutil.copy2(file_path, student_folder / clean_filename)

    # Add extracted typed text / comments into student folders
    for key, data in typed_comments.items():
        students_found.add(key)
        student_folder = students_dir / key
        student_folder.mkdir(exist_ok=True)
        
        txt_path = student_folder / f"{key}_Typed_Text.txt"
        txt_path.write_text(f"Student: {data['display']}\nSource: D2L Comments / Dialogue\n\n{data['text']}", encoding='utf-8')

    # Image compilation into single PDF packet per student folder
    print("Checking for photo rough work to compile...")
    for student_folder in students_dir.iterdir():
        if not student_folder.is_dir():
            continue
        
        imgs = sorted([p for p in student_folder.iterdir() if p.suffix.lower() in IMAGE_EXTS])
        if len(imgs) > 0:
            pdf_out = student_folder / f"{student_folder.name}_Images_Combined.pdf"
            compile_images_to_pdf(imgs, pdf_out)

    # Summary report
    summary_csv = reports_dir / "submission_summary.csv"
    with open(summary_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(["StudentKey", "FileCount", "HasTypedText", "HasCombinedPDF"])
        for student_folder in sorted(students_dir.iterdir()):
            if student_folder.is_dir():
                files = list(student_folder.iterdir())
                has_text = any(f.name.endswith('_Typed_Text.txt') for f in files)
                has_pdf = any(f.name.endswith('_Images_Combined.pdf') for f in files)
                writer.writerow([student_folder.name, len(files), has_text, has_pdf])

    # Clean up temporary extraction directory
    shutil.rmtree(temp_extract, ignore_errors=True)

    # Create mark_next.py launcher script inside workspace
    generate_launcher_script(work_dir)

    print("\n" + "=" * 60)
    print(" SETUP COMPLETE ✅")
    print("=" * 60)
    print(f"Workspace Directory: {work_dir}")
    print(f"Student Directories: {students_dir}")
    print(f"Launcher Script:     {work_dir / 'mark_next.py'}")
    print("\nTo start marking, run:")
    print(f"  python3 {work_dir / 'mark_next.py'}\n")

if __name__ == "__main__":
    main()
