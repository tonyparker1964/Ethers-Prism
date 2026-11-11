"""Ether's Prism launcher for ltx-2-mlx on a 24 GB Mac.

Two fixes, applied without editing the runtime:
1. Per-layer evaluation in the Gemma 4 text tower (see below).
2. A lower memory peak while encoding the prompt:

The stock PromptEncoder keeps Gemma (~10.5 GB) and the connector (~4 GB) loaded
together while it stacks Gemma's 49 layer outputs, which goes past macOS's GPU
memory cap on a 24 GB Mac and stalls the GPU ("GPU Timeout"). Here Gemma runs
alone, its outputs are kept, Gemma is released, and only then is the connector
loaded. Same math, lower peak. Set LTX_PRISM_STOCK_ENCODER=1 to use the original.
"""
import os
import sys

import mlx.core as mx
from ltx_core_mlx.utils.memory import aggressive_cleanup
from ltx_core_mlx.text_encoders.gemma import gemma4
from ltx_pipelines_mlx.utils import blocks

# LTX-2.5's Gemma 4 tower runs all 48 layers as one lazy graph, i.e. one huge GPU
# job that macOS kills ("GPU Timeout"). The Gemma 3 path evaluates every layer
# (LTX2_GEMMA_EVAL_EVERY, default 1); do the same for Gemma 4.
_EVAL_EVERY = int(os.environ.get("LTX2_GEMMA_EVAL_EVERY", "1"))
if _EVAL_EVERY > 0:
    _orig_layer_call = gemma4.Gemma4DecoderLayer.__call__
    _layer_count = [0]

    _TRACE = os.environ.get("LTX_PRISM_TRACE") == "1"

    def _layer_call(self, *args, **kwargs):
        out = _orig_layer_call(self, *args, **kwargs)
        _layer_count[0] += 1
        if _layer_count[0] % _EVAL_EVERY == 0:
            if _TRACE:
                import time
                t0 = time.time()
                print(f"  gemma layer {_layer_count[0]} ...", file=sys.stderr, flush=True)
            mx.eval(out)
            if _TRACE:
                print(f"  gemma layer {_layer_count[0]} done in {time.time() - t0:.2f}s", file=sys.stderr, flush=True)
        return out

    gemma4.Gemma4DecoderLayer.__call__ = _layer_call

_orig_load = blocks.PromptEncoder.load
_SKIP = object()  # stands in for a module so load() skips loading it


def _encode_low_peak(self, prompt):
    max_length = int(os.environ.get("LTX2_GEMMA_MAX_LENGTH", "1024"))
    # 1) Gemma only.
    had_connector = self._feature_extractor is not None
    if not had_connector:
        self._feature_extractor = _SKIP
    _orig_load(self)
    if not had_connector:
        self._feature_extractor = None
    # Gemma's first GPU job stalls on this Mac (GPU Timeout), so by default the
    # prompt is read on the CPU. Set LTX_PRISM_GEMMA_DEVICE=gpu to try the GPU.
    device = mx.cpu if os.environ.get("LTX_PRISM_GEMMA_DEVICE", "cpu") == "cpu" else mx.gpu
    if os.environ.get("LTX_PRISM_TRACE") == "1":
        print(f"  gemma on {device}", file=sys.stderr, flush=True)
    with mx.stream(device):
        hidden, mask = self._text_encoder.encode_all_layers(prompt, max_length=max_length)
        mx.eval(*hidden, mask)
    # 2) Release Gemma before the connector comes in.
    self._text_encoder = None
    aggressive_cleanup()
    # 3) Connector only.
    self._text_encoder = _SKIP
    _orig_load(self)
    self._text_encoder = None
    return self._feature_extractor(hidden, attention_mask=mask)


if os.environ.get("LTX_PRISM_STOCK_ENCODER") != "1":
    blocks.PromptEncoder.encode = _encode_low_peak
    # The pipeline preloads Gemma + connector together; encode() now loads each when needed.
    blocks.PromptEncoder.load = lambda self: None

from ltx_pipelines_mlx.cli import main  # noqa: E402

sys.argv[0] = "ltx-2-mlx"
main()
