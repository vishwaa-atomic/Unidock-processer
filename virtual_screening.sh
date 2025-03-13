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
find . -name "*.sdf" -type f -print0 | xargs -0 -n 100 -P 12 -I {} sh -c '
    file="$1"
    output="processed_ligands/ligand_$(basename "$1" .sdf).sdf"
    if timeout 5s obabel "$file" -O "$output" --gen3D 2>/dev/null; then
        echo "Processed: $file" >> '"$LOG_FILE"'
    else
        echo "Skipped (timeout): $file" >> '"$LOG_FILE"'
    fi
' sh {}

# Step 5: Create ligand index file
log_message "Creating ligand index file..."
find "$SCRIPT_DIR/processed_ligands" -name "*.sdf" -type f > "$SCRIPT_DIR/ligand_index.txt"
total_ligands=$(wc -l < "$SCRIPT_DIR/ligand_index.txt")
log_message "Found $total_ligands ligands to process"

# Step 6: Monitor progress
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