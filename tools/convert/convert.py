#!/usr/bin/env python3
"""Rebuild Kadr's AI model packages from the original, official weights — and check the published ones.

    python convert.py build faceID            # → dist/faceID/ and dist/kadr-faceID-1.zip
    python convert.py build all
    python convert.py verify kadr-faceID-1.zip  # rebuild, then compare with a published archive

Every source file is pinned by URL and SHA-256. Conversion with the pinned tool versions
(requirements.txt) gives byte-identical model.mlmodel and weights/weight.bin, so `verify` compares file
hashes, not "close enough" numbers. One exception: tf2onnx may list the face mesh's blendshapes graph in
another order; then the weights must still match and both models must give bit-identical outputs.
Each conversion also prints how far Core ML's output is from the original model's.

Packages:
  facemesh  MediaPipe Face Landmarker (Google)   TFLite → ONNX → PyTorch → Core ML   (bundled with the app)
  faceID    SFace (OpenCV Zoo)                   ONNX → PyTorch → Core ML
  denoise   SCUNet (Kai Zhang et al.)            PyTorch → Core ML
  retouch   SAM 2.1 Small (Apple's Core ML) + LaMa (Core ML) — downloaded as is, only checked
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, urllib.request, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
DIST = HERE / "dist"

SOURCES = {
    "face_landmarker.task": (
        "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
        "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"),
    "sface.onnx": (
        "https://github.com/opencv/opencv_zoo/raw/ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
        "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"),
    "scunet_color_real_psnr.pth": (
        "https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth",
        "fa78899ba2caec9d235a900e91d96c689da71c42029230c2028b00f09f809c2e"),
    "network_scunet.py": (
        "https://raw.githubusercontent.com/cszn/SCUNet/52e440a80a655b01e0b41e9dd9bfe599bc11625e/models/network_scunet.py",
        None),  # patched below; the patch asserts the exact lines it replaces
}

# Hugging Face repositories at pinned revisions; the files are used unchanged.
HF = {
    "apple/coreml-sam2.1-small@883f5787eb0be35ce6965907a8bc1f5320a5a02e": [
        "SAM2_1SmallImageEncoderFLOAT16", "SAM2_1SmallPromptEncoderFLOAT16", "SAM2_1SmallMaskDecoderFLOAT16"],
    "mlboydaisuke/LaMa-CoreML@5ed76e3799ab4cad31381750d29880c267477e18": ["LaMa"],
}

EXPECTED = json.loads((HERE / "expected.json").read_text())
ARCHIVE = {"facemesh": "kadr-facemesh-1", "faceID": "kadr-faceID-1", "denoise": "kadr-denoise-1", "retouch": "kadr-retouch-1"}


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fetch(url, dst, expected=None):
    dst = Path(dst)
    if not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        print(f"  ↓ {url}")
        tmp = dst.with_suffix(dst.suffix + ".part")
        with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
        tmp.rename(dst)
    if expected and sha256(dst) != expected:
        dst.unlink()
        sys.exit(f"SHA-256 mismatch for {dst.name} — the source changed or the download is broken")
    return dst


def source(name):
    url, sha = SOURCES[name]
    return fetch(url, CACHE / name, sha)


def to_coreml(torch_model, example, inputs, outputs, path, fp16):
    import torch, coremltools as ct
    torch.manual_seed(0)
    ml = ct.convert(torch.jit.trace(torch_model, example),
                    inputs=[ct.TensorType(name=n, shape=s) for n, s in inputs],
                    outputs=[ct.TensorType(name=n) for n in outputs],
                    minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT16 if fp16 else ct.precision.FLOAT32)
    ml.save(str(path))
    return ml


def unfold_prelu(tm):
    """onnx2torch's PReLU becomes non_zero/scatter in Core ML (off the Neural Engine, ~70× slower);
    relu(x) − a·relu(−x) is the same function in plain ops."""
    import torch

    class PReLU(torch.nn.Module):
        def forward(self, x, a):
            return torch.relu(x) - a * torch.relu(-x)

    for name, mod in list(tm.named_modules()):
        if type(mod).__name__ == "OnnxPReLU":
            parent = tm.get_submodule(name.rsplit(".", 1)[0]) if "." in name else tm
            setattr(parent, name.rsplit(".", 1)[-1], PReLU())
    if hasattr(tm, "graph"):
        tm.graph.lint(); tm.recompile()
    return tm


def build_facemesh(out):
    import numpy as np, onnx, onnx2torch, onnxruntime as ort, torch
    work = Path(tempfile.mkdtemp())
    with zipfile.ZipFile(source("face_landmarker.task")) as z:
        z.extractall(work)
    specs = [("face_landmarks_detector", (1, 256, 256, 3), 1, ["landmarks", "presence", "handedness"], True),
             ("face_blendshapes", (1, 146, 2), 500, ["blendshapes"], False)]
    for name, shape, scale, outs, fp16 in specs:
        onnx_path = work / f"{name}.onnx"
        subprocess.run([sys.executable, "-m", "tf2onnx.convert", "--tflite", str(work / f"{name}.tflite"),
                        "--output", str(onnx_path)], check=True, capture_output=True)
        tm = onnx2torch.convert(onnx.load(str(onnx_path))).eval()
        if fp16:
            tm = unfold_prelu(tm)
        torch.manual_seed(0)
        x = torch.rand(shape) * scale
        ml = to_coreml(tm, x, [("input", shape)], outs, out / f"{name}.mlpackage", fp16)
        s = ort.InferenceSession(str(onnx_path))
        xn = (np.random.default_rng(1).random(shape) * scale).astype(np.float32)
        ref = s.run(None, {s.get_inputs()[0].name: xn})
        got = ml.predict({"input": xn})
        unit = " px of a 256 px face crop (float16)" if fp16 else ""
        print(f"  {name}: max |Core ML − original| = {float(np.abs(got[outs[0]].reshape(ref[0].shape) - ref[0]).max()):.5f}{unit}")
    shutil.rmtree(work)


def build_faceID(out):
    import numpy as np, onnx, onnx2torch, onnxruntime as ort, torch
    src = source("sface.onnx")
    tm = unfold_prelu(onnx2torch.convert(onnx.load(str(src))).eval())
    x = (np.random.default_rng(0).random((1, 3, 112, 112)) * 255).astype(np.float32)
    ml = to_coreml(tm, torch.tensor(x), [("input", (1, 3, 112, 112))], ["embedding"], out / "sface.mlpackage", True)
    s = ort.InferenceSession(str(src))
    ref = s.run(None, {s.get_inputs()[0].name: x})[0]
    got = ml.predict({"input": x})["embedding"].reshape(ref.shape)
    print(f"  sface: cosine(Core ML, original) = {float((got * ref).sum() / np.linalg.norm(got) / np.linalg.norm(ref)):.5f}")


def build_denoise(out):
    import numpy as np, torch
    code = source("network_scunet.py").read_text().replace("\r\n", "\n")
    # The model code needs two changes for Core ML; everything else, including the weights, is the original.
    patches = [
        ("from thop import profile\n", "# thop (profiling only) not needed\n"),
        # The shifted-window mask is built with numpy: it depends only on the fixed tile shape, so tracing
        # turns it into a constant (Core ML has no boolean tensor assignment).
        ("""        attn_mask = torch.zeros(h, w, p, p, p, p, dtype=torch.bool, device=self.relative_position_params.device)
        if self.type == 'W':
            return attn_mask

        s = p - shift
        attn_mask[-1, :, :s, :, s:, :] = True
        attn_mask[-1, :, s:, :, :s, :] = True
        attn_mask[:, -1, :, :s, :, s:] = True
        attn_mask[:, -1, :, s:, :, :s] = True
        attn_mask = rearrange(attn_mask, 'w1 w2 p1 p2 p3 p4 -> 1 1 (w1 w2) (p1 p2) (p3 p4)')
        return attn_mask
""", """        m = np.zeros((h, w, p, p, p, p), dtype=np.float32)
        if self.type == 'W':
            return torch.from_numpy(m.reshape(1, 1, h * w, p * p, p * p))
        s = p - shift
        m[-1, :, :s, :, s:, :] = 1
        m[-1, :, s:, :, :s, :] = 1
        m[:, -1, :, :s, :, s:] = 1
        m[:, -1, :, s:, :, :s] = 1
        return torch.from_numpy(m.reshape(1, 1, h * w, p * p, p * p))
"""),
        # Additive mask instead of masked_fill(-inf): fp16-safe, identical after softmax.
        ("""            sim = sim.masked_fill_(attn_mask, float("-inf"))""",
         """            sim = sim - attn_mask * 1e4"""),
    ]
    for old, new in patches:
        assert code.count(old) == 1, "network_scunet.py differs from the pinned revision"
        code = code.replace(old, new)
    mod_dir = Path(tempfile.mkdtemp())
    (mod_dir / "network_scunet.py").write_text(code)
    sys.path.insert(0, str(mod_dir))
    from network_scunet import SCUNet
    m = SCUNet(in_nc=3, config=[4, 4, 4, 4, 4, 4, 4], dim=64)
    m.load_state_dict(torch.load(source("scunet_color_real_psnr.pth"), map_location="cpu"), strict=True)
    m.eval()
    torch.manual_seed(0)
    x = torch.rand(1, 3, 512, 512)
    with torch.no_grad():
        ref = m(x).numpy()
        ml = to_coreml(m, x, [("input", (1, 3, 512, 512))], ["output"], out / "scunet512.mlpackage", True)
    got = ml.predict({"input": x.numpy()})["output"]
    print(f"  scunet: max |Core ML − original| = {float(np.abs(got - ref).max()):.4f} (pixel values 0…1)")
    shutil.rmtree(mod_dir)


def build_retouch(out):
    for spec, names in HF.items():
        repo, rev = spec.split("@")
        for n in names:
            for f in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]:
                rel = f"{n}.mlpackage/{f}"
                cached = fetch(f"https://huggingface.co/{repo}/resolve/{rev}/{rel}", CACHE / repo.replace("/", "_") / rel,
                               EXPECTED["retouch"][rel])
                (out / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(cached, out / rel)
    print("  retouch: SAM 2.1 and LaMa files match the pinned revisions")


def build(pkg):
    out = DIST / pkg
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    print(f"== {pkg}")
    globals()[f"build_{pkg}"](out)
    shutil.copyfile(HERE / "notices" / f"{pkg}.txt", out / "NOTICE.txt")
    shutil.copyfile(HERE / "notices" / "LICENSE-Apache-2.0.txt", out / "LICENSE-Apache-2.0.txt")
    zip_path = DIST / f"{ARCHIVE[pkg]}.zip"
    zip_path.unlink(missing_ok=True)
    if pkg == "facemesh":   # build.sh expects a top-level kadr-facemesh-1/ folder
        stage = DIST / ARCHIVE[pkg]
        shutil.rmtree(stage, ignore_errors=True)
        shutil.copytree(out, stage)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(stage), str(zip_path)], check=True)
        shutil.rmtree(stage)
    else:
        subprocess.run(["ditto", "-c", "-k", str(out), str(zip_path)], check=True)
    bad = compare(out, EXPECTED[pkg])
    print(f"  → {zip_path.relative_to(HERE)}: " + ("identical to the published models" if not bad else f"DIFFERS: {', '.join(bad)}"))
    return bad


def model_files(root):
    """Hashes of what defines a model. Manifest.json of converted models carries random item IDs, so it is
    left out for them; the downloaded (unchanged) packages are compared in full."""
    root = Path(root)
    return {str(p.relative_to(root)): sha256(p) for p in sorted(root.rglob("*"))
            if p.is_file() and ".mlpackage/" in str(p.relative_to(root)) and p.name != ".DS_Store"}


def compare(root, expected):
    got = model_files(root)
    return [k for k, v in expected.items() if got.get(k) != v]


def same_outputs(a_pkg, b_pkg, runs=50):
    """Runs both models on the CPU on the same random inputs; True if every output is bit-identical.
    Used when a rebuilt model.mlmodel lists the same graph in another order (tf2onnx numbers tensors
    differently between runs) while the weights are identical."""
    import numpy as np, coremltools as ct
    a = ct.models.MLModel(str(a_pkg), compute_units=ct.ComputeUnit.CPU_ONLY)
    b = ct.models.MLModel(str(b_pkg), compute_units=ct.ComputeUnit.CPU_ONLY)
    rng = np.random.default_rng(7)
    for _ in range(runs):
        x = {i.name: rng.random(tuple(i.type.multiArrayType.shape)).astype(np.float32) for i in a.get_spec().description.input}
        ra, rb = a.predict(x), b.predict(x)
        if any(not np.array_equal(ra[k], rb[k]) for k in ra):
            return False
    return True


def verify(zip_path):
    zip_path = Path(zip_path).resolve()
    pkg = next((k for k, v in ARCHIVE.items() if zip_path.name.startswith(v)), None)
    if not pkg:
        sys.exit(f"unknown archive {zip_path.name}")
    published = Path(tempfile.mkdtemp())
    subprocess.run(["ditto", "-x", "-k", str(zip_path), str(published)], check=True)
    if pkg == "facemesh":
        published = published / ARCHIVE[pkg]
    bad_pub = compare(published, EXPECTED[pkg])
    bad_new = build(pkg)
    for f in list(bad_new):
        pkg_dir = f.split("/")[0]
        weights = f"{pkg_dir}/Data/com.apple.CoreML/weights/weight.bin"
        if f.endswith("model.mlmodel") and weights not in bad_new and same_outputs(published / pkg_dir, DIST / pkg / pkg_dir):
            print(f"  {pkg_dir}: same weights, bit-identical outputs; only the order of the graph differs")
            bad_new.remove(f)
    print(f"\n{zip_path.name}: published archive " + ("matches" if not bad_pub else f"DIFFERS ({', '.join(bad_pub)})")
          + " the expected hashes; rebuilt from the originals: " + ("identical" if not bad_new else "DIFFERENT"))
    sys.exit(1 if bad_pub or bad_new else 0)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("package", choices=[*ARCHIVE, "all"])
    v = sub.add_parser("verify"); v.add_argument("zip")
    a = ap.parse_args()
    if a.cmd == "build":
        bad = [p for p in (ARCHIVE if a.package == "all" else [a.package]) if build(p)]
        sys.exit(1 if bad else 0)
    verify(a.zip)
