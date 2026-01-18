#!/bin/bash
#
# Setup script for ohhhllama HuggingFace module
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
DATA_DIR="/data/huggingface"

echo "=== ohhhllama HuggingFace Setup ==="
echo ""

# Check if running as appropriate user
if [[ $EUID -eq 0 ]]; then
    echo "Note: Running as root"
fi

# Create virtual environment
echo "Creating Python virtual environment..."
python3 -m venv "$VENV_DIR"

# Activate and install dependencies
echo "Installing dependencies..."
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$SCRIPT_DIR/requirements.txt"

echo ""
echo "Virtual environment created at: $VENV_DIR"
echo ""
echo "To activate: source $VENV_DIR/bin/activate"
echo ""

# Check data directory permissions
if [[ -d "$DATA_DIR" ]]; then
    echo "Data directory exists: $DATA_DIR"
    if [[ -w "$DATA_DIR" ]]; then
        echo "  ✓ Writable"
    else
        echo "  ✗ Not writable - run: sudo chown -R $USER:$USER $DATA_DIR"
    fi
else
    echo "Data directory does not exist: $DATA_DIR"
    echo "  Run: sudo mkdir -p $DATA_DIR && sudo chown -R $USER:$USER $DATA_DIR"
fi

echo ""
echo "Setup complete!"
echo ""
echo "Test with:"
echo "  source $VENV_DIR/bin/activate"
echo "  python3 $SCRIPT_DIR/hf_backend.py TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF"
