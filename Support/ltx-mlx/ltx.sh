#!/bin/zsh
# Runs the LTX-2.5 MLX command line from the MAC Mini 2 drive. Ether's Prism calls this.
# Usage: ltx.sh generate ... | ltx.sh --help
ROOT="/Volumes/MAC Mini 2/LTX"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
export UV_CACHE_DIR="$ROOT/.uv-cache"
export UV_PYTHON_INSTALL_DIR="$ROOT/.python"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
# A 24 GB Mac can run past macOS's per-job GPU time limit while Gemma reads the prompt.
# This relaxes it for the LTX process only (the screen may feel slower during a render).
export AGX_RELAX_CDM_CTXSTORE_TIMEOUT="${AGX_RELAX_CDM_CTXSTORE_TIMEOUT:-1}"
[[ -d "$ROOT/ltx-2-mlx" ]] || { echo "LTX isn't installed. Run 'Install LTX Video.command' on the MAC Mini 2 drive." >&2; exit 2; }
# Keep the Mac awake while this process runs.
caffeinate -i -w $$ &
exec uv run --project "$ROOT/ltx-2-mlx" python "$ROOT/ltx_launch.py" "$@"
