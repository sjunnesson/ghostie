#!/usr/bin/env python3
"""Export speechbrain/lang-id-voxlingua107-ecapa to ONNX for Ghostie's LID.

Produces ~/.ghostie/models/lid-voxlingua107.onnx (+ .labels.json) with the
feature pipeline (fbank + mean-var norm) INSIDE the graph, so Ghostie feeds
raw 16 kHz Float32 waveform and reads 107 language logits. Once the file is
in place (and `brew install onnxruntime` has been run), `ghostie doctor`
shows "VoxLingua107 ECAPA-TDNN (ONNX, …)" as the active language identifier
— no config change needed.

One-time setup on the exporting machine (any Mac/Linux with Python 3.10+):

    python3 -m venv /tmp/vox-export && source /tmp/vox-export/bin/activate
    pip install torch speechbrain onnx onnxscript onnxruntime
    python3 scripts/export-voxlingua-lid.py

(`onnxscript` is what torch's current exporter runs on; without it the export
dies on `ModuleNotFoundError: No module named 'onnxscript'`.)

Model + weights: speechbrain/lang-id-voxlingua107-ecapa (Apache-2.0).
The export is for local use; if you redistribute the .onnx, keep the
Apache-2.0 attribution.
"""

import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", default=os.path.expanduser("~/.ghostie/models"),
                    help="destination directory (default: ~/.ghostie/models)")
    ap.add_argument("--opset", type=int, default=17,
                    help="ONNX opset (17+ needed for in-graph STFT)")
    ap.add_argument("--seconds", type=float, default=2.0,
                    help="dummy-input length used for tracing")
    args = ap.parse_args()

    try:
        import torch
        from speechbrain.inference.classifiers import EncoderClassifier
    except ImportError as e:
        print(f"missing dependency: {e}\n"
              "run: pip install torch speechbrain onnx onnxruntime", file=sys.stderr)
        return 1

    print("Loading speechbrain/lang-id-voxlingua107-ecapa (downloads ~90 MB on first run)…")
    clf = EncoderClassifier.from_hparams(
        source="speechbrain/lang-id-voxlingua107-ecapa",
        savedir=os.path.expanduser("~/.cache/ghostie-voxlingua"))
    clf.eval()

    class Wrapper(torch.nn.Module):
        """Raw waveform [1, N] → language logits [1, 107], features in-graph."""

        def __init__(self, clf):
            super().__init__()
            self.compute_features = clf.mods.compute_features
            self.mean_var_norm = clf.mods.mean_var_norm
            self.embedding_model = clf.mods.embedding_model
            self.classifier = clf.mods.classifier

        def forward(self, wav):
            lens = torch.ones(wav.shape[0], device=wav.device)
            feats = self.compute_features(wav)
            feats = self.mean_var_norm(feats, lens)
            emb = self.embedding_model(feats, lens)
            # [1, 1, 107] → [1, 107]. Whether this layer emits raw logits or
            # log-softmax does not matter to Ghostie: softmax is shift-
            # invariant, so its posterior is identical either way.
            return self.classifier(emb).squeeze(1)

    wrapper = Wrapper(clf)
    dummy = torch.zeros(1, int(16_000 * args.seconds), dtype=torch.float32)

    os.makedirs(args.out_dir, exist_ok=True)
    onnx_path = os.path.join(args.out_dir, "lid-voxlingua107.onnx")
    labels_path = onnx_path + ".labels.json"

    print(f"Exporting to {onnx_path} (opset {args.opset})…")
    torch.onnx.export(
        wrapper, (dummy,), onnx_path,
        input_names=["wav"], output_names=["logits"],
        dynamic_axes={"wav": {1: "samples"}},
        opset_version=args.opset,
    )

    # Fold external weights back into the .onnx. Torch's current exporter
    # splits anything over its size threshold into a sibling
    # `lid-voxlingua107.onnx.data`, which Ghostie has no idea about: it checks
    # (and, for the .dmg, bundles) the single path it was given, and
    # `VoxLingua107LID.isReady` would say yes to a graph whose weights aren't
    # there — then fail *structurally* on the first segment, which backlogs
    # the whole call instead of falling back to the whisper LID. One
    # self-contained file keeps that contract true.
    try:
        import onnx
        if os.path.exists(onnx_path + ".data"):
            model = onnx.load(onnx_path, load_external_data=True)
            onnx.save(model, onnx_path, save_as_external_data=False)
            os.remove(onnx_path + ".data")
            print(f"Folded external weights into {onnx_path} "
                  f"({os.path.getsize(onnx_path) / 1e6:.0f} MB, self-contained)")
    except ImportError:
        print("WARNING: onnx not installed — cannot check for external weights.",
              file=sys.stderr)

    # Labels in output-index order. VoxLingua107 entries look like
    # "en: English" — Ghostie wants the bare ISO code.
    enc = clf.hparams.label_encoder
    labels = [str(enc.ind2lab[i]).split(":")[0].strip().lower()
              for i in range(len(enc.ind2lab))]
    with open(labels_path, "w") as f:
        json.dump(labels, f)
    print(f"Wrote {len(labels)} labels to {labels_path}")

    # Parity check when the onnxruntime python package is available: the
    # ONNX graph must agree with PyTorch on a random input.
    try:
        import numpy as np
        import onnxruntime as ort
        test = torch.randn(1, 24_000) * 0.05
        want = wrapper(test).detach().numpy()
        sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
        got = sess.run(["logits"], {"wav": test.numpy()})[0]
        if np.allclose(want, got, atol=1e-3):
            print("Parity check: ONNX output matches PyTorch ✓")
        else:
            print("WARNING: ONNX output diverges from PyTorch "
                  f"(max abs diff {np.abs(want - got).max():.4f}) — "
                  "inspect before trusting routing.", file=sys.stderr)
    except ImportError:
        print("(onnxruntime python package not installed — skipped parity check)")

    print("\nDone. Ghostie will pick the model up automatically:\n"
          "  brew install onnxruntime   # if not already installed\n"
          "  ghostie doctor             # should show 'VoxLingua107 ECAPA-TDNN (ONNX, …)'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
