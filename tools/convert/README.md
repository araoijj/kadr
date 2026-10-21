# Rebuilding the AI models

Kadr runs its AI models with Apple Core ML. The original authors publish most of them in other formats
(TFLite, ONNX, PyTorch), so Kadr distributes converted copies — the MediaPipe face mesh inside the app,
the optional packages as the [`models-2`](https://github.com/araoijj/kadr/releases/tag/models-2) release.

This folder lets anyone check that those copies are exactly the original models, converted and nothing else:
`convert.py` downloads the original weights from their authors, converts them, and compares the result
with the published files.

| Package | Original | Changes |
|---|---|---|
| `kadr-facemesh-1` (in the app) | [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker), Google, Apache 2.0 | TFLite → ONNX → PyTorch → Core ML; PReLU written as `relu(x) − a·relu(−x)` |
| `kadr-faceID-1` | [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface), OpenCV Zoo, Apache 2.0 | ONNX → PyTorch → Core ML (float16); same PReLU rewrite |
| `kadr-denoise-1` | [SCUNet](https://github.com/cszn/SCUNet), Kai Zhang et al., Apache 2.0 | PyTorch → Core ML (float16, 512×512 tile); the attention mask is precomputed (two-line patch in `convert.py`) |
| `kadr-retouch-1` | [SAM 2.1 Small, Core ML by Apple](https://huggingface.co/apple/coreml-sam2.1-small) + [LaMa, Core ML](https://huggingface.co/mlboydaisuke/LaMa-CoreML), Apache 2.0 | none — the files are downloaded as is |

Every source is pinned by URL (a fixed revision) and SHA-256, so a changed upstream file is reported, not silently used.

## How to check

macOS on Apple Silicon, Python 3.12. The tools take ~2 GB (TensorFlow is needed only for the face mesh).

```sh
cd tools/convert
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python convert.py verify ~/Downloads/kadr-faceID-1.zip   # one published archive
.venv/bin/python convert.py build all                             # or rebuild everything into dist/
```

`verify` unpacks the archive, rebuilds the same package from the originals and compares the model files
(`model.mlmodel` and `weights/weight.bin` of every `.mlpackage`) by SHA-256. With the pinned tool versions
the files come out **identical**, not just close; their hashes are also listed in `expected.json`.
One exception: tf2onnx sometimes lists the face mesh's blendshapes graph in another order. Then `verify`
requires identical weights and runs both models on the same inputs: the outputs must match bit for bit.

During conversion the script also runs the original model and the Core ML one on the same input and prints
the difference (cosine 1.0000 for SFace, ≤0.0005 for SCUNet), which shows the conversion itself is faithful.

## How the app checks downloads

The SHA-256 of each published archive is written into the app (`ModelPackages.swift`, `ModelChecksum`;
`build.sh` for the face mesh). A downloaded archive that doesn't match is never installed. A file chosen with
«Из файла…» that doesn't match — for example, one you rebuilt here — is installed only after a confirmation.
