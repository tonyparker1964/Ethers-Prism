#!/bin/zsh
# Ether's Prism · Video agent setup
# Installs LTX-2.5 for Apple Silicon (MLX) entirely on the MAC Mini 2 drive.
# Runtime: github.com/dgrauet/ltx-2-mlx   Model: huggingface.co/dgrauet/ltx-2.5-mlx-q4 (4-bit)
# Everything runs on this Mac. Nothing is sent to Lightricks.
set -e
ROOT="/Volumes/MAC Mini 2/LTX"
MODEL_REPO="dgrauet/ltx-2.5-mlx-q4"
MODEL_DIR="$ROOT/models/ltx-2.5-mlx-q4"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
unset HOMEBREW_ASK; export NONINTERACTIVE=1 HOMEBREW_NO_ENV_HINTS=1
export UV_CACHE_DIR="$ROOT/.uv-cache"
export UV_PYTHON_INSTALL_DIR="$ROOT/.python"

say_step() { print -P "\n%F{magenta}▸ $1%f"; }

[[ -d "/Volumes/MAC Mini 2" ]] || { echo "The MAC Mini 2 drive isn't mounted."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "This needs an Apple Silicon Mac."; exit 1; }
mkdir -p "$ROOT/models" "$ROOT/renders"
cd "$ROOT"

say_step "1/4  Tools (uv, ffmpeg, git)"
if ! command -v uv >/dev/null; then
  if command -v brew >/dev/null; then yes | brew install uv; else curl -LsSf https://astral.sh/uv/install.sh | sh; fi
fi
if ! command -v ffmpeg >/dev/null; then
  command -v brew >/dev/null || { echo "ffmpeg is missing and Homebrew isn't installed. Install Homebrew from https://brew.sh, then run this again."; exit 1; }
  yes | brew install ffmpeg
fi
command -v git >/dev/null || xcode-select --install
uv --version; ffmpeg -version | head -1

say_step "2/4  LTX runtime (MLX port)"
if [[ -d ltx-2-mlx/.git ]]; then git -C ltx-2-mlx pull --ff-only; else git clone https://github.com/dgrauet/ltx-2-mlx.git; fi
(cd ltx-2-mlx && uv sync --all-extras)

say_step "3/4  LTX-2.5 model, 4-bit (about 25 GB, onto the drive)"
HF=(uvx --from "huggingface_hub[hf_xet]" hf)
if ! "${HF[@]}" auth whoami >/dev/null 2>&1; then
  echo "This model is gated. First, on https://huggingface.co/$MODEL_REPO click 'Agree and access'."
  echo "Then paste a Hugging Face read token (huggingface.co/settings/tokens) when asked:"
  "${HF[@]}" auth login
fi
# Only the distilled (fast, 8-step) pipeline is used, so the dev transformer and its LoRA are skipped.
"${HF[@]}" download "$MODEL_REPO" --local-dir "$MODEL_DIR" \
  --exclude "transformer-dev*" --exclude "*distilled-lora*"

say_step "4/4  Test clip"
"$ROOT/ltx.sh" generate --model "$MODEL_DIR" --distilled --low-ram \
  -p "A glowing prism floating in a dark cosmic void, slowly rotating, rainbow light spilling from its edges, soft particles drifting, slow push-in camera" \
  -H 256 -W 448 -f 25 --frame-rate 24 -o "$ROOT/renders/test-clip.mp4"
echo "\nDone. Test clip: $ROOT/renders/test-clip.mp4"
open "$ROOT/renders/test-clip.mp4" 2>/dev/null || true
