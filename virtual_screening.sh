#!/bin/bash

# Set up logging
LOG_FILE="virtual_screening.log"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Function to log messages
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Function to check required commands
check_requirements() {
    local required_commands=("obabel" "unidock" "unidocktools" "python3")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_message "ERROR: Required command '$cmd' not found. Please install it first."
            exit 1
        fi
    done
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -c CURL_FILE    Path to the .curl file to extract"
    echo "  -p PDB_FILE     Path to the input PDB file"
    echo "  -x CENTER_X     Center X coordinate for docking (default: 30.562)"
    echo "  -y CENTER_Y     Center Y coordinate for docking (default: 28.936)"
    echo "  -z CENTER_Z     Center Z coordinate for docking (default: 27.561)"
    echo "  -sx SIZE_X     Size X for docking box (default: 20)"
    echo "  -sy SIZE_Y     Size Y for docking box (default: 20)"
    echo "  -sz SIZE_Z     Size Z for docking box (default: 20)"
    echo "  -m MEM         Max GPU memory in MB (default: 20480)"
    echo "  -h             Show this help message"
}

# Default values
CENTER_X=30.562
CENTER_Y=28.936
CENTER_Z=27.561
SIZE_X=20
SIZE_Y=20
SIZE_Z=20
MAX_GPU_MEM=20480

# Parse command line arguments
while getopts "c:p:x:y:z:sx:sy:sz:m:h" opt; do
    case $opt in
        c) CURL_FILE="$OPTARG" ;;
        p) PDB_FILE="$OPTARG" ;;
        x) CENTER_X="$OPTARG" ;;
        y) CENTER_Y="$OPTARG" ;;
        z) CENTER_Z="$OPTARG" ;;
        sx) SIZE_X="$OPTARG" ;;
        sy) SIZE_Y="$OPTARG" ;;
        sz) SIZE_Z="$OPTARG" ;;
        m) MAX_GPU_MEM="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) usage; exit 1 ;;
    esac
done

# Check if required files are provided
if [ -z "$CURL_FILE" ]; then
    log_message "ERROR: CURL file path is required"
    usage
    exit 1
fi

if [ -z "$PDB_FILE" ]; then
    log_message "ERROR: PDB file path is required"
    usage
    exit 1
fi

# Create required directories
mkdir -p "$SCRIPT_DIR"/{processed_ligands,prepared_protein,docking_output}

# Step 1: Prepare protein structure
log_message "Preparing protein structure..."
if [ ! -f "$PDB_FILE" ]; then
    log_message "ERROR: PDB file not found: $PDB_FILE"
    exit 1
fi

RECEPTOR_PDBQT="$SCRIPT_DIR/prepared_protein/receptor.pdbqt"
log_message "Running protein preparation..."
if ! unidocktools proteinprep -r "$PDB_FILE" -o "$RECEPTOR_PDBQT"; then
    log_message "ERROR: Protein preparation failed"
    exit 1
fi
log_message "Protein preparation completed successfully"

# Step 2: Extract CURL file
log_message "Extracting CURL file: $CURL_FILE"
if [ -f "$CURL_FILE" ]; then
    chmod +x "$CURL_FILE"
    ./"$CURL_FILE"
else
    log_message "ERROR: CURL file not found: $CURL_FILE"
    exit 1
fi

# Step 3: Extract all .gz files
log_message "Extracting .gz files..."
find . -name "*.gz" -exec gunzip {} \;

# Step 4: Process ligands with OpenBabel
log_message "Processing ligands with OpenBabel..."
# First, count total input files
total_input_files=$(find . -name "*.sdf" -type f | wc -l)
log_message "Found $total_input_files input SDF files"

# Create required directories
mkdir -p "$SCRIPT_DIR/processed_ligands"

# Process each file individually with better error handling
find . -name "*.sdf" -type f | while read -r file; do
    output_file="$SCRIPT_DIR/processed_ligands/ligand_$(basename "$file" .sdf).sdf"
    log_message "Processing file: $file"
    
    # Try to process with OpenBabel
    if timeout 10s obabel "$file" -O "$output_file" --gen3D 2>> "$LOG_FILE"; then
        log_message "Successfully processed: $file"
    else
        log_message "Failed to process: $file"
        # Try to get more information about the file
        log_message "File size: $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file") bytes"
        log_message "File permissions: $(ls -l "$file" 2>/dev/null)"
    fi
done

# Count processed files
processed_files=$(find "$SCRIPT_DIR/processed_ligands" -name "*.sdf" -type f | wc -l)
log_message "Successfully processed $processed_files out of $total_input_files files"

# Step 5: Sanitize ligands
log_message "Sanitizing ligands..."
# Create list of SDF files
find "$SCRIPT_DIR/processed_ligands" -maxdepth 1 -name "*.sdf" > "$SCRIPT_DIR/ligand.txt"
remaining_files=$(wc -l < "$SCRIPT_DIR/ligand.txt")
log_message "Starting sanitization of $remaining_files files"

# Create prepared_ligands directory if it doesn't exist
mkdir -p "$SCRIPT_DIR/prepared_ligands"

# Split into batches of 100 files
split -l 100 "$SCRIPT_DIR/ligand.txt" "$SCRIPT_DIR/batch_"

# Process each batch
for batch in "$SCRIPT_DIR/batch_"*; do
    if [ -f "$batch" ]; then
        log_message "Processing batch: $batch"
        # Count files in this batch
        batch_count=$(wc -l < "$batch")
        log_message "Batch contains $batch_count files"
        
        # Process this batch and capture output
        output=$(timeout 10s unidocktools ligandprep -i "$batch" -sd "$SCRIPT_DIR/prepared_ligands" 2>&1)
        
        # Log the output for debugging
        log_message "Ligandprep output:"
        echo "$output" >> "$LOG_FILE"
        
        # Check for errors in this batch
        if [ $? -ne 0 ]; then
            # Extract problematic files from WARNING messages
            error_files=$(echo "$output" | grep "WARNING.*ligand.*is invalid mol" | sed -n 's/.*ligand \(.*\) idx.*/\1/p')
            
            # Remove each problematic file
            while IFS= read -r file; do
                if [ ! -z "$file" ] && [ -f "$file" ]; then
                    rm "$file"
                    log_message "Removed invalid file: $(basename "$file")"
                fi
            done <<< "$error_files"
        fi
        
        # Clean up batch file
        rm "$batch"
    fi
done

# Count files after sanitization
sanitized_files=$(find "$SCRIPT_DIR/prepared_ligands" -name "*.sdf" -type f | wc -l)
log_message "After sanitization: $sanitized_files files remaining"

# Step 6: Create ligand index file
log_message "Creating ligand index file..."
find "$SCRIPT_DIR/prepared_ligands" -name "*.sdf" -type f > "$SCRIPT_DIR/ligand_index.txt"
total_ligands=$(wc -l < "$SCRIPT_DIR/ligand_index.txt")
log_message "Found $total_ligands sanitized ligands to process"

# Verify the ligand index file
log_message "Contents of ligand_index.txt:"
cat "$SCRIPT_DIR/ligand_index.txt" >> "$LOG_FILE"

# Step 7: Monitor progress
log_message "Setting up progress monitoring..."
cat > "$SCRIPT_DIR/monitor_progress.py" << 'EOF'
import os
import glob
import time

def extract_energy(file_path):
    try:
        with open(file_path, 'r') as f:
            content = f.read()
            conformers = content.split('$$$$')
            first_conf = conformers[0]
            for line in first_conf.split('\n'):
                if line.startswith('ENERGY='):
                    return float(line.split('=')[1].strip().split()[0])
    except:
        return float('inf')
    return float('inf')

def monitor_progress(output_dir, log_file):
    while True:
        sdf_files = glob.glob(os.path.join(output_dir, '*.sdf'))
        total_files = len(sdf_files)
        
        lowest_energy = float('inf')
        lowest_energy_file = None
        
        for sdf_file in sdf_files:
            energy = extract_energy(sdf_file)
            if energy < lowest_energy:
                lowest_energy = energy
                lowest_energy_file = sdf_file
        
        timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
        status = f"[{timestamp}] Progress: {total_files} files processed"
        if lowest_energy_file:
            status += f", Lowest energy: {lowest_energy} ({os.path.basename(lowest_energy_file)})"
        
        with open(log_file, 'a') as f:
            f.write(status + '\n')
        
        time.sleep(3600)  # Wait for 1 hour

if __name__ == "__main__":
    import sys
    monitor_progress(sys.argv[1], sys.argv[2])
EOF

# Start the monitoring script in the background
python3 "$SCRIPT_DIR/monitor_progress.py" "$SCRIPT_DIR/docking_output" "$LOG_FILE" &
MONITOR_PID=$!

# Run Unidock
log_message "Running Unidock with following parameters:"
log_message "Center: ($CENTER_X, $CENTER_Y, $CENTER_Z)"
log_message "Box size: ($SIZE_X, $SIZE_Y, $SIZE_Z)"
log_message "Receptor: $RECEPTOR_PDBQT"
log_message "Max GPU Memory: $MAX_GPU_MEM MB"

# Run Unidock with absolute paths
unidock --receptor "$(realpath "$RECEPTOR_PDBQT")" \
        --ligand_index "$(realpath "$SCRIPT_DIR/ligand_index.txt")" \
        --center_x "$CENTER_X" \
        --center_y "$CENTER_Y" \
        --center_z "$CENTER_Z" \
        --size_x "$SIZE_X" \
        --size_y "$SIZE_Y" \
        --size_z "$SIZE_Z" \
        --dir "$(realpath "$SCRIPT_DIR/docking_output")" \
        --max_gpu_memory "$MAX_GPU_MEM"

# Kill the monitoring script
kill $MONITOR_PID

# Final analysis for lowest energy conformation
log_message "Performing final analysis..."
python3 - << 'EOF'
import os
import glob

def extract_energy(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
        conformers = content.split('$$$$')
        first_conf = conformers[0]
        for line in first_conf.split('\n'):
            if line.startswith('ENERGY='):
                try:
                    return float(line.split('=')[1].strip().split()[0])
                except:
                    return float('inf')
    return float('inf')

output_dir = os.path.join(os.getcwd(), 'docking_output')
sdf_files = glob.glob(os.path.join(output_dir, '*.sdf'))

if not sdf_files:
    print("No SDF files found in the output directory")
else:
    lowest_energy = float('inf')
    lowest_energy_file = None
    
    for sdf_file in sdf_files:
        energy = extract_energy(sdf_file)
        if energy < lowest_energy:
            lowest_energy = energy
            lowest_energy_file = sdf_file
    
    if lowest_energy_file:
        print(f"Final results:")
        print(f"File with lowest energy: {os.path.basename(lowest_energy_file)}")
        print(f"Energy value: {lowest_energy}")
    else:
        print("No valid energy values found in any files")
EOF

log_message "Virtual screening process completed!"

# Step 8: Organize files into finished folder
log_message "Organizing files into finished folder..."
FINISHED_DIR="$SCRIPT_DIR/finished"
mkdir -p "$FINISHED_DIR"

# Enable extended globbing
shopt -s extglob

# Move everything except the specified files to finished folder
for item in !(virtual_screening.sh|"ZINC-downloader-3D-sdf.gz (1).curl"|vs-rep.c1.pdb|docking_output|virtual_screening.log); do
    if [ -e "$item" ]; then
        mv "$item" "$FINISHED_DIR/"
        log_message "Moved $item to finished folder"
    fi
done

# Disable extended globbing
shopt -u extglob

# Final directory structure message
log_message "Final directory structure:"
log_message "- $SCRIPT_DIR/virtual_screening.sh (main script)"
log_message "- $SCRIPT_DIR/virtual_screening.log (log file)"
log_message "- $SCRIPT_DIR/docking_output/ (docking results)"
log_message "- $SCRIPT_DIR/vs-rep.c1.pdb (input protein)"
log_message "- $SCRIPT_DIR/ZINC-downloader-3D-sdf.gz (1).curl (input curl file)"
log_message "- $FINISHED_DIR/ (all other files and directories)" 