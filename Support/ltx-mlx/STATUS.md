# LTX-2.5 on this Mac (MLX): parked

These are the scripts that go in `/Volumes/MAC Mini 2/LTX` (runtime: github.com/dgrauet/ltx-2-mlx, model: dgrauet/ltx-2.5-mlx-q4).

Status on the M4 Mac mini, 24 GB (Nov 11, 2026): the model installs, but every run fails while the Gemma 4 text encoder reads the prompt, with `[METAL] ... GPU Timeout Error (kIOGPUCommandBufferCallbackErrorTimeout)` on MLX 0.32.2.

Tried, in `ltx_launch.py`:
- Per-layer evaluation of the Gemma 4 tower (the Gemma 3 path already does this; Gemma 4 runs all 48 layers as one GPU job). Now it fails on layer 1.
- Releasing Gemma before the connector loads (lower memory peak). Not the cause: 65% of memory was free.
- `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1` in `ltx.sh`. No change.
- Shorter prompt window (`LTX2_GEMMA_MAX_LENGTH=256`). Still fails on layer 1.

Not yet tried: Gemma on the CPU (`LTX_PRISM_GEMMA_DEVICE=cpu`, now the default in `ltx_launch.py`), a different MLX version, the 8-bit pack.
