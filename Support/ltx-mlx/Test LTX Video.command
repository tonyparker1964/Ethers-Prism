#!/bin/zsh
# Renders a short test clip with LTX-2.5 and logs the run to renders/test.log.
ROOT="/Volumes/MAC Mini 2/LTX"
LOG="$ROOT/renders/test.log"
mkdir -p "$ROOT/renders"
# Free memory: LTX needs most of the 24 GB.
[[ -x "$HOME/.lmstudio/bin/lms" ]] && "$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1
{
  echo "=== $(date)"
  echo "--- memory before the run"
  memory_pressure 2>/dev/null | tail -1
  sysctl -n iogpu.wired_limit_mb 2>/dev/null | sed 's/^/GPU wired limit MB (0 = default): /'
  ps -axo rss=,comm= | sort -rn | head -8 | awk '{printf "%6.1f GB  %s\n", $1/1048576, $2}'
  echo "---"
  LTX_PRISM_TRACE=1 LTX2_GEMMA_MAX_LENGTH=${LTX2_GEMMA_MAX_LENGTH:-256} /usr/bin/time -l "$ROOT/ltx.sh" generate --model "$ROOT/models/ltx-2.5-mlx-q4" --distilled --low-ram \
    -p "A glowing glass prism floating in a dark cosmic void, slowly rotating, rainbow light spilling from its edges, soft particles drifting, slow push-in camera" \
    -H 256 -W 448 -f 25 --frame-rate 24 -o "$ROOT/renders/test-clip.mp4"
  echo "=== exit $?  $(date)"
} 2>&1 | tee "$LOG"
[[ -s "$ROOT/renders/test-clip.mp4" ]] && open "$ROOT/renders/test-clip.mp4"
