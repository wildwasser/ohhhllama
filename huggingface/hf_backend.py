#!/usr/bin/env python3
"""
HuggingFace Backend Module for Ollama Integration

This module provides functionality to:
- Check HuggingFace models for compatibility
- Download GGUF files or convert models to GGUF format
- Import models into Ollama

Usage:
    python hf_backend.py <repo_id> [model_name] [quant]
"""

import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# =============================================================================
# Configuration
# =============================================================================

HF_CACHE_DIR = Path("/data/huggingface")
OLLAMA_MODELS_DIR = Path("/data/ollama")
LLAMA_CPP_DIR = Path("/opt/llama.cpp")
DEFAULT_QUANT = "Q4_K_M"

# HuggingFace API base URL
HF_API_BASE = "https://huggingface.co/api"

# Docker container name for Ollama (when running in Docker)
OLLAMA_CONTAINER = os.environ.get("OLLAMA_CONTAINER", "ollama")

# Ollama API host
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11435")

# Supported architectures for conversion to GGUF
SUPPORTED_ARCHITECTURES = [
    "LlamaForCausalLM",
    "MistralForCausalLM",
    "MixtralForCausalLM",
    "Qwen2ForCausalLM",
    "PhiForCausalLM",
    "Phi3ForCausalLM",
    "GemmaForCausalLM",
    "Gemma2ForCausalLM",
    "FalconForCausalLM",
    "GPT2LMHeadModel",
    "GPTNeoXForCausalLM",
    "StableLmForCausalLM",
    "OlmoForCausalLM",
]

# Known GGUF providers (checked in order)
GGUF_PROVIDERS = [
    "TheBloke",
    "bartowski",
    "QuantFactory",
    "mradermacher",
]

# Quantization type preferences (from highest to lowest quality)
QUANT_PREFERENCES = [
    "Q8_0",
    "Q6_K",
    "Q5_K_M",
    "Q5_K_S",
    "Q4_K_M",
    "Q4_K_S",
    "Q4_0",
    "Q3_K_M",
    "Q3_K_S",
    "Q2_K",
]

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


# =============================================================================
# Data Classes
# =============================================================================


@dataclass
class ModelInfo:
    """Information about a HuggingFace model."""

    repo_id: str
    architecture: Optional[str] = None
    is_convertible: bool = False
    has_gguf: bool = False
    gguf_files: List[str] = field(default_factory=list)
    gguf_repo: Optional[str] = None
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "repo_id": self.repo_id,
            "architecture": self.architecture,
            "is_convertible": self.is_convertible,
            "has_gguf": self.has_gguf,
            "gguf_files": self.gguf_files,
            "gguf_repo": self.gguf_repo,
            "error": self.error,
        }


@dataclass
class ProcessResult:
    """Result of processing a HuggingFace model."""

    status: str  # "completed", "failed", "partial"
    steps: List[Dict[str, Any]] = field(default_factory=list)
    error: Optional[str] = None
    model_name: Optional[str] = None
    gguf_path: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "status": self.status,
            "steps": self.steps,
            "error": self.error,
            "model_name": self.model_name,
            "gguf_path": self.gguf_path,
        }


# =============================================================================
# HuggingFace API Functions
# =============================================================================


def hf_api_request(
    endpoint: str, token: Optional[str] = None
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """
    Make a request to the HuggingFace API.

    Args:
        endpoint: API endpoint (relative to HF_API_BASE)
        token: Optional HuggingFace API token

    Returns:
        Tuple of (response_data, error_message)
    """
    url = f"{HF_API_BASE}/{endpoint}"
    headers = {"Accept": "application/json"}

    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
            return data, None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, f"Repository not found: {endpoint}"
        elif e.code == 401:
            return None, "Authentication required. Please provide a valid HF token."
        elif e.code == 403:
            return None, "Access denied. This may be a gated model requiring authentication."
        else:
            return None, f"HTTP error {e.code}: {e.reason}"
    except urllib.error.URLError as e:
        return None, f"Network error: {e.reason}"
    except json.JSONDecodeError as e:
        return None, f"Failed to parse API response: {e}"
    except Exception as e:
        return None, f"Unexpected error: {e}"


def get_repo_files(repo_id: str, token: Optional[str] = None) -> Tuple[List[str], Optional[str]]:
    """
    Get list of files in a HuggingFace repository.

    Args:
        repo_id: HuggingFace repository ID (e.g., "meta-llama/Llama-2-7b")
        token: Optional HuggingFace API token

    Returns:
        Tuple of (file_list, error_message)
    """
    data, error = hf_api_request(f"models/{repo_id}", token)

    if error:
        return [], error

    if not data:
        return [], "Empty response from API"

    # Extract file names from siblings
    siblings = data.get("siblings", [])
    files = [s.get("rfilename", "") for s in siblings if s.get("rfilename")]

    return files, None


def get_model_config(
    repo_id: str, token: Optional[str] = None
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """
    Fetch and parse config.json from a HuggingFace repository.

    Args:
        repo_id: HuggingFace repository ID
        token: Optional HuggingFace API token

    Returns:
        Tuple of (config_dict, error_message)
    """
    url = f"https://huggingface.co/{repo_id}/raw/main/config.json"
    headers = {"Accept": "application/json"}

    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            config = json.loads(response.read().decode("utf-8"))
            return config, None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, "config.json not found in repository"
        return None, f"HTTP error {e.code}: {e.reason}"
    except Exception as e:
        return None, f"Failed to fetch config: {e}"


# =============================================================================
# Model Checking Functions
# =============================================================================


def search_gguf_repo(repo_id: str, token: Optional[str] = None) -> Optional[str]:
    """
    Search for an existing GGUF repository for a given model.

    Checks common GGUF providers like TheBloke, bartowski, etc.

    Args:
        repo_id: Original HuggingFace repository ID
        token: Optional HuggingFace API token

    Returns:
        GGUF repository ID if found, None otherwise
    """
    # Extract model name from repo_id
    model_name = repo_id.split("/")[-1]

    # Common name variations to check
    name_variations = [
        model_name,
        model_name.replace("-", "_"),
        model_name.replace("_", "-"),
    ]

    for provider in GGUF_PROVIDERS:
        for name in name_variations:
            # Try different naming conventions
            candidates = [
                f"{provider}/{name}-GGUF",
                f"{provider}/{name}-gguf",
                f"{provider}/{name.lower()}-GGUF",
            ]

            for candidate in candidates:
                logger.debug(f"Checking for GGUF repo: {candidate}")
                files, error = get_repo_files(candidate, token)

                if not error and files:
                    # Verify it actually has GGUF files
                    gguf_files = [f for f in files if f.endswith(".gguf")]
                    if gguf_files:
                        logger.info(f"Found GGUF repository: {candidate}")
                        return candidate

    return None


def check_model(repo_id: str, token: Optional[str] = None) -> ModelInfo:
    """
    Check a HuggingFace model for Ollama compatibility.

    Determines if the model:
    - Already has GGUF files
    - Can be converted to GGUF
    - Has an existing GGUF version from a provider

    Args:
        repo_id: HuggingFace repository ID
        token: Optional HuggingFace API token

    Returns:
        ModelInfo with compatibility information
    """
    info = ModelInfo(repo_id=repo_id)

    # Get repository files
    logger.info(f"Checking model: {repo_id}")
    files, error = get_repo_files(repo_id, token)

    if error:
        info.error = error
        return info

    # Check for existing GGUF files
    gguf_files = [f for f in files if f.endswith(".gguf")]

    if gguf_files:
        info.has_gguf = True
        info.gguf_files = gguf_files
        info.gguf_repo = repo_id
        logger.info(f"Model has {len(gguf_files)} GGUF file(s)")
        return info

    # No GGUF files - check if model is convertible
    config, config_error = get_model_config(repo_id, token)

    if config_error:
        logger.warning(f"Could not fetch config: {config_error}")
    else:
        # Check architecture from config
        architectures = config.get("architectures", [])
        if architectures:
            info.architecture = architectures[0]
            info.is_convertible = info.architecture in SUPPORTED_ARCHITECTURES

            if info.is_convertible:
                logger.info(f"Model architecture '{info.architecture}' is supported for conversion")
            else:
                logger.warning(f"Architecture '{info.architecture}' is not supported for conversion")

    # Search for existing GGUF repositories
    logger.info("Searching for existing GGUF repositories...")
    gguf_repo = search_gguf_repo(repo_id, token)

    if gguf_repo:
        info.gguf_repo = gguf_repo
        # Get the GGUF files from that repo
        gguf_files, _ = get_repo_files(gguf_repo, token)
        info.gguf_files = [f for f in gguf_files if f.endswith(".gguf")]
        info.has_gguf = True
        logger.info(f"Found GGUF repo: {gguf_repo} with {len(info.gguf_files)} file(s)")

    return info


# =============================================================================
# GGUF Selection and Download Functions
# =============================================================================


def select_gguf_file(gguf_files: List[str], quant: str = DEFAULT_QUANT) -> Optional[str]:
    """
    Select the best GGUF file matching the quantization preference.

    Args:
        gguf_files: List of available GGUF filenames
        quant: Preferred quantization type

    Returns:
        Selected filename or None if no match found
    """
    if not gguf_files:
        return None

    # Normalize quant type for matching
    quant_upper = quant.upper().replace("-", "_")

    # First, try exact match
    for f in gguf_files:
        f_upper = f.upper()
        if quant_upper in f_upper:
            logger.info(f"Selected GGUF file (exact match): {f}")
            return f

    # Try to find closest quantization in preference order
    quant_index = QUANT_PREFERENCES.index(quant_upper) if quant_upper in QUANT_PREFERENCES else -1

    if quant_index >= 0:
        # Search for alternatives in preference order (prefer higher quality)
        for alt_quant in QUANT_PREFERENCES:
            for f in gguf_files:
                if alt_quant in f.upper():
                    logger.info(f"Selected GGUF file (alternative {alt_quant}): {f}")
                    return f

    # Fall back to first file
    logger.info(f"Selected GGUF file (fallback): {gguf_files[0]}")
    return gguf_files[0]


def download_gguf(
    repo_id: str,
    filename: str,
    output_dir: Path,
    token: Optional[str] = None,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Download a GGUF file from HuggingFace.

    Supports resume for interrupted downloads.

    Args:
        repo_id: HuggingFace repository ID
        filename: GGUF filename to download
        output_dir: Directory to save the file
        token: Optional HuggingFace API token

    Returns:
        Tuple of (output_path, error_message)
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / filename

    url = f"https://huggingface.co/{repo_id}/resolve/main/{filename}"

    logger.info(f"Downloading: {url}")
    logger.info(f"Destination: {output_path}")

    # Try using huggingface-cli first (better for large files)
    if shutil.which("huggingface-cli"):
        cmd = [
            "huggingface-cli",
            "download",
            repo_id,
            filename,
            "--local-dir",
            str(output_dir),
            "--local-dir-use-symlinks",
            "False",
        ]

        if token:
            cmd.extend(["--token", token])

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=3600  # 1 hour timeout
            )

            if result.returncode == 0:
                # huggingface-cli may place file in subdirectory
                if output_path.exists():
                    return str(output_path), None
                # Search for the file
                for path in output_dir.rglob(filename):
                    return str(path), None

                return None, "Download completed but file not found"
            else:
                logger.warning(f"huggingface-cli failed: {result.stderr}")
        except subprocess.TimeoutExpired:
            return None, "Download timed out"
        except Exception as e:
            logger.warning(f"huggingface-cli error: {e}")

    # Fall back to wget with resume support
    if shutil.which("wget"):
        cmd = ["wget", "-c", "-O", str(output_path), url]

        if token:
            cmd.insert(1, f"--header=Authorization: Bearer {token}")

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)

            if result.returncode == 0 and output_path.exists():
                return str(output_path), None
            else:
                return None, f"wget failed: {result.stderr}"
        except subprocess.TimeoutExpired:
            return None, "Download timed out"
        except Exception as e:
            return None, f"wget error: {e}"

    # Fall back to urllib (no resume support)
    logger.warning("Using urllib (no resume support)")
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=3600) as response:
            with open(output_path, "wb") as f:
                shutil.copyfileobj(response, f)
        return str(output_path), None
    except Exception as e:
        return None, f"Download failed: {e}"


def download_model_for_conversion(
    repo_id: str,
    output_dir: Path,
    token: Optional[str] = None,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Download a model's safetensors files for GGUF conversion.

    Args:
        repo_id: HuggingFace repository ID
        output_dir: Directory to save the model
        token: Optional HuggingFace API token

    Returns:
        Tuple of (model_directory, error_message)
    """
    output_dir = Path(output_dir)
    model_dir = output_dir / repo_id.replace("/", "_")
    model_dir.mkdir(parents=True, exist_ok=True)

    logger.info(f"Downloading model for conversion: {repo_id}")
    logger.info(f"Destination: {model_dir}")

    # Use huggingface-cli for full model download
    if shutil.which("huggingface-cli"):
        cmd = [
            "huggingface-cli",
            "download",
            repo_id,
            "--local-dir",
            str(model_dir),
            "--local-dir-use-symlinks",
            "False",
            "--include",
            "*.safetensors",
            "--include",
            "*.json",
            "--include",
            "tokenizer*",
        ]

        if token:
            cmd.extend(["--token", token])

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)

            if result.returncode == 0:
                # Verify essential files exist
                config_path = model_dir / "config.json"
                if config_path.exists():
                    return str(model_dir), None
                else:
                    return None, "Download completed but config.json not found"
            else:
                return None, f"Download failed: {result.stderr}"
        except subprocess.TimeoutExpired:
            return None, "Download timed out"
        except Exception as e:
            return None, f"Download error: {e}"

    return None, "huggingface-cli not available for model download"


# =============================================================================
# Conversion Functions
# =============================================================================


def convert_to_gguf(
    model_dir: str,
    output_path: str,
    dtype: str = "f16",
) -> Tuple[Optional[str], Optional[str]]:
    """
    Convert a HuggingFace model to GGUF format using llama.cpp.

    Args:
        model_dir: Path to the downloaded model directory
        output_path: Path for the output GGUF file
        dtype: Data type for conversion (f16, f32, bf16)

    Returns:
        Tuple of (output_path, error_message)
    """
    convert_script = LLAMA_CPP_DIR / "convert_hf_to_gguf.py"

    if not convert_script.exists():
        return None, f"Conversion script not found: {convert_script}"

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    logger.info(f"Converting model to GGUF: {model_dir}")
    logger.info(f"Output: {output_path}")

    cmd = [
        sys.executable,
        str(convert_script),
        model_dir,
        "--outfile",
        str(output_path),
        "--outtype",
        dtype,
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3600,
            cwd=str(LLAMA_CPP_DIR),
        )

        if result.returncode == 0 and output_path.exists():
            logger.info(f"Conversion successful: {output_path}")
            return str(output_path), None
        else:
            error_msg = result.stderr or result.stdout or "Unknown error"
            return None, f"Conversion failed: {error_msg}"
    except subprocess.TimeoutExpired:
        return None, "Conversion timed out"
    except Exception as e:
        return None, f"Conversion error: {e}"


def quantize_gguf(
    input_path: str,
    output_path: str,
    quant_type: str = DEFAULT_QUANT,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Quantize a GGUF file using llama-quantize.

    Args:
        input_path: Path to the input GGUF file
        output_path: Path for the quantized output
        quant_type: Quantization type (Q4_K_M, Q5_K_M, etc.)

    Returns:
        Tuple of (output_path, error_message)
    """
    quantize_bin = LLAMA_CPP_DIR / "llama-quantize"

    # Try alternative names
    if not quantize_bin.exists():
        quantize_bin = LLAMA_CPP_DIR / "quantize"
    if not quantize_bin.exists():
        quantize_bin = LLAMA_CPP_DIR / "build" / "bin" / "llama-quantize"

    if not quantize_bin.exists():
        return None, f"llama-quantize not found in {LLAMA_CPP_DIR}"

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    logger.info(f"Quantizing GGUF: {input_path}")
    logger.info(f"Quantization type: {quant_type}")
    logger.info(f"Output: {output_path}")

    cmd = [str(quantize_bin), input_path, str(output_path), quant_type]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)

        if result.returncode == 0 and output_path.exists():
            logger.info(f"Quantization successful: {output_path}")
            return str(output_path), None
        else:
            error_msg = result.stderr or result.stdout or "Unknown error"
            return None, f"Quantization failed: {error_msg}"
    except subprocess.TimeoutExpired:
        return None, "Quantization timed out"
    except Exception as e:
        return None, f"Quantization error: {e}"


# =============================================================================
# Ollama Integration Functions
# =============================================================================


def create_modelfile(
    gguf_path: str,
    model_name: str,
    system_prompt: Optional[str] = None,
    template: Optional[str] = None,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Generate an Ollama Modelfile for importing a GGUF model.

    Args:
        gguf_path: Path to the GGUF file
        model_name: Name for the Ollama model
        system_prompt: Optional system prompt
        template: Optional chat template

    Returns:
        Tuple of (modelfile_path, error_message)
    """
    gguf_path = Path(gguf_path)

    if not gguf_path.exists():
        return None, f"GGUF file not found: {gguf_path}"

    modelfile_dir = OLLAMA_MODELS_DIR / "modelfiles"
    modelfile_dir.mkdir(parents=True, exist_ok=True)
    modelfile_path = modelfile_dir / f"{model_name}.Modelfile"

    lines = [f"FROM {gguf_path}"]

    if system_prompt:
        # Escape quotes in system prompt
        escaped_prompt = system_prompt.replace('"', '\\"')
        lines.append(f'SYSTEM "{escaped_prompt}"')

    if template:
        lines.append(f"TEMPLATE {template}")

    # Add some reasonable defaults
    lines.extend(
        [
            "",
            "# Default parameters",
            "PARAMETER temperature 0.7",
            "PARAMETER top_p 0.9",
            "PARAMETER stop <|im_end|>",
            "PARAMETER stop <|end|>",
            "PARAMETER stop </s>",
        ]
    )

    content = "\n".join(lines)

    try:
        with open(modelfile_path, "w") as f:
            f.write(content)
        logger.info(f"Created Modelfile: {modelfile_path}")
        return str(modelfile_path), None
    except Exception as e:
        return None, f"Failed to create Modelfile: {e}"


def import_to_ollama(modelfile_path: str, model_name: str) -> Tuple[bool, Optional[str]]:
    """
    Import a model into Ollama.
    
    Uses docker exec to create a temp Modelfile inside the container and run ollama create.

    Args:
        modelfile_path: Path to the Modelfile
        model_name: Name for the Ollama model

    Returns:
        Tuple of (success, error_message)
    """
    modelfile_path = Path(modelfile_path)
    if not modelfile_path.exists():
        return False, f"Modelfile not found: {modelfile_path}"

    # Read the Modelfile content
    try:
        with open(modelfile_path, 'r') as f:
            modelfile_content = f.read()
    except Exception as e:
        return False, f"Failed to read Modelfile: {e}"

    logger.info(f"Importing model to Ollama: {model_name}")

    # Sanitize model name - lowercase, replace underscores with hyphens
    safe_model_name = model_name.lower().replace('_', '-')
    
    # Escape the modelfile content for shell
    # Replace single quotes with escaped version for shell
    escaped_content = modelfile_content.replace("'", "'\\''")
    
    # Use docker exec to:
    # 1. Write Modelfile to temp location inside container
    # 2. Run ollama create
    # 3. Clean up temp file
    cmd = [
        "sudo", "docker", "exec", OLLAMA_CONTAINER,
        "sh", "-c",
        f"echo '{escaped_content}' > /tmp/Modelfile && ollama create {safe_model_name} -f /tmp/Modelfile && rm /tmp/Modelfile"
    ]
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=600
        )
        
        if result.returncode == 0:
            logger.info(f"Successfully imported model: {safe_model_name}")
            return True, None
        else:
            error_msg = result.stderr or result.stdout or "Unknown error"
            return False, f"Import failed: {error_msg}"
            
    except subprocess.TimeoutExpired:
        return False, "Import timed out"
    except Exception as e:
        return False, f"Import error: {e}"


# =============================================================================
# Main Processing Pipeline
# =============================================================================


def process_huggingface_model(
    repo_id: str,
    model_name: Optional[str] = None,
    quant: str = DEFAULT_QUANT,
    token: Optional[str] = None,
    cleanup: bool = True,
) -> Dict[str, Any]:
    """
    Full pipeline to process a HuggingFace model for Ollama.

    Steps:
    1. Check model compatibility
    2. Download GGUF or convert model
    3. Import to Ollama

    Args:
        repo_id: HuggingFace repository ID
        model_name: Name for the Ollama model (defaults to repo name)
        quant: Quantization type for conversion
        token: Optional HuggingFace API token
        cleanup: Whether to clean up intermediate files

    Returns:
        Dictionary with status, steps, and error information
    """
    result = ProcessResult(status="in_progress")
    steps = []

    # Default model name from repo_id
    if not model_name:
        # Sanitize: lowercase, keep hyphens, remove special chars
        raw_name = repo_id.split("/")[-1].lower()
        model_name = ''.join(c if c.isalnum() or c == '-' else '-' for c in raw_name)
        # Remove consecutive hyphens and strip
        while '--' in model_name:
            model_name = model_name.replace('--', '-')
        model_name = model_name.strip('-')

    result.model_name = model_name

    def add_step(name: str, status: str, details: Optional[str] = None):
        step = {"name": name, "status": status}
        if details:
            step["details"] = details
        steps.append(step)
        logger.info(f"Step '{name}': {status}" + (f" - {details}" if details else ""))

    # Step 1: Check model
    add_step("check_model", "running")
    model_info = check_model(repo_id, token)

    if model_info.error:
        add_step("check_model", "failed", model_info.error)
        result.status = "failed"
        result.error = model_info.error
        result.steps = steps
        return result.to_dict()

    add_step("check_model", "completed", f"Architecture: {model_info.architecture}")

    gguf_path = None
    temp_dirs = []

    try:
        # Step 2: Get GGUF file
        if model_info.has_gguf and model_info.gguf_repo:
            # Download existing GGUF
            add_step("select_gguf", "running")
            gguf_file = select_gguf_file(model_info.gguf_files, quant)

            if not gguf_file:
                add_step("select_gguf", "failed", "No suitable GGUF file found")
                result.status = "failed"
                result.error = "No suitable GGUF file found"
                result.steps = steps
                return result.to_dict()

            add_step("select_gguf", "completed", f"Selected: {gguf_file}")

            add_step("download_gguf", "running")
            output_dir = HF_CACHE_DIR / "gguf"
            gguf_path, error = download_gguf(model_info.gguf_repo, gguf_file, output_dir, token)

            if error:
                add_step("download_gguf", "failed", error)
                result.status = "failed"
                result.error = error
                result.steps = steps
                return result.to_dict()

            add_step("download_gguf", "completed", f"Downloaded to: {gguf_path}")

        elif model_info.is_convertible:
            # Convert model to GGUF
            add_step("download_model", "running")
            temp_dir = Path(tempfile.mkdtemp(prefix="hf_convert_"))
            temp_dirs.append(temp_dir)

            model_dir, error = download_model_for_conversion(repo_id, temp_dir, token)

            if error:
                add_step("download_model", "failed", error)
                result.status = "failed"
                result.error = error
                result.steps = steps
                return result.to_dict()

            add_step("download_model", "completed", f"Downloaded to: {model_dir}")

            # Convert to GGUF (f16 first)
            add_step("convert_to_gguf", "running")
            f16_path = temp_dir / f"{model_name}_f16.gguf"
            gguf_path, error = convert_to_gguf(model_dir, str(f16_path), "f16")

            if error:
                add_step("convert_to_gguf", "failed", error)
                result.status = "failed"
                result.error = error
                result.steps = steps
                return result.to_dict()

            add_step("convert_to_gguf", "completed", f"Created: {gguf_path}")

            # Quantize if needed
            if quant.upper() != "F16":
                add_step("quantize", "running")
                output_dir = HF_CACHE_DIR / "gguf"
                output_dir.mkdir(parents=True, exist_ok=True)
                quant_path = output_dir / f"{model_name}_{quant}.gguf"

                final_path, error = quantize_gguf(gguf_path, str(quant_path), quant)

                if error:
                    add_step("quantize", "failed", error)
                    result.status = "failed"
                    result.error = error
                    result.steps = steps
                    return result.to_dict()

                gguf_path = final_path
                add_step("quantize", "completed", f"Created: {gguf_path}")

        else:
            # Cannot process this model
            error_msg = (
                f"Model cannot be processed: architecture '{model_info.architecture}' "
                "is not supported and no GGUF version found"
            )
            add_step("check_model", "failed", error_msg)
            result.status = "failed"
            result.error = error_msg
            result.steps = steps
            return result.to_dict()

        # Step 3: Create Modelfile and import to Ollama
        add_step("create_modelfile", "running")
        modelfile_path, error = create_modelfile(gguf_path, model_name)

        if error:
            add_step("create_modelfile", "failed", error)
            result.status = "failed"
            result.error = error
            result.steps = steps
            return result.to_dict()

        add_step("create_modelfile", "completed", f"Created: {modelfile_path}")

        add_step("import_to_ollama", "running")
        success, error = import_to_ollama(modelfile_path, model_name)

        if not success:
            add_step("import_to_ollama", "failed", error)
            result.status = "failed"
            result.error = error
            result.steps = steps
            return result.to_dict()

        add_step("import_to_ollama", "completed", f"Model '{model_name}' is ready")

        result.status = "completed"
        result.gguf_path = gguf_path
        result.steps = steps

    finally:
        # Cleanup temporary directories
        if cleanup:
            for temp_dir in temp_dirs:
                try:
                    shutil.rmtree(temp_dir, ignore_errors=True)
                    logger.debug(f"Cleaned up: {temp_dir}")
                except Exception:
                    pass

    return result.to_dict()


# =============================================================================
# CLI Interface
# =============================================================================


def print_model_info(info: ModelInfo) -> None:
    """Print ModelInfo in a formatted way."""
    print("\n" + "=" * 60)
    print(f"Model: {info.repo_id}")
    print("=" * 60)

    if info.error:
        print(f"Error: {info.error}")
        return

    print(f"Architecture:   {info.architecture or 'Unknown'}")
    print(f"Is Convertible: {info.is_convertible}")
    print(f"Has GGUF:       {info.has_gguf}")

    if info.gguf_repo:
        print(f"GGUF Repo:      {info.gguf_repo}")

    if info.gguf_files:
        print(f"GGUF Files:     ({len(info.gguf_files)} files)")
        for f in info.gguf_files[:10]:  # Show first 10
            print(f"  - {f}")
        if len(info.gguf_files) > 10:
            print(f"  ... and {len(info.gguf_files) - 10} more")

    print()


def main():
    """CLI entry point for testing."""
    if len(sys.argv) < 2:
        print("Usage: python hf_backend.py <repo_id> [model_name] [quant]")
        print()
        print("Examples:")
        print("  python hf_backend.py meta-llama/Llama-2-7b")
        print("  python hf_backend.py TheBloke/Llama-2-7B-GGUF llama2 Q4_K_M")
        print()
        print("Environment variables:")
        print("  HF_TOKEN - HuggingFace API token for gated models")
        sys.exit(1)

    repo_id = sys.argv[1]
    model_name = sys.argv[2] if len(sys.argv) > 2 else None
    quant = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_QUANT

    # Get token from environment
    token = os.environ.get("HF_TOKEN")

    # Step 1: Check the model
    print("\nChecking model...")
    info = check_model(repo_id, token)
    print_model_info(info)

    if info.error:
        sys.exit(1)

    # Ask user if they want to proceed with full processing
    if info.has_gguf or info.is_convertible:
        print("Would you like to process this model for Ollama? [y/N] ", end="")
        try:
            response = input().strip().lower()
        except EOFError:
            response = "n"

        if response in ("y", "yes"):
            print("\nProcessing model...")
            result = process_huggingface_model(
                repo_id=repo_id,
                model_name=model_name,
                quant=quant,
                token=token,
                cleanup=True,
            )

            print("\n" + "=" * 60)
            print("Processing Result")
            print("=" * 60)
            print(json.dumps(result, indent=2))

            if result["status"] == "completed":
                print(f"\nSuccess! Model '{result['model_name']}' is ready to use.")
                print(f"Run: ollama run {result['model_name']}")
            else:
                print(f"\nFailed: {result.get('error', 'Unknown error')}")
                sys.exit(1)
    else:
        print("This model cannot be processed for Ollama.")
        print("It either has an unsupported architecture or no GGUF version is available.")
        sys.exit(1)


if __name__ == "__main__":
    main()
