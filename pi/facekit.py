#!/usr/bin/env python3
"""facekit: face detection (YuNet) + recognition (SFace) on a Raspberry Pi 5 with Camera Module 3.

Runs headless (no GUI). Annotated frames are written to ~/envlab/out/ for inspection.

Modes
  test    --image PATH            detect faces in a still image, write annotated copy
  live    [--seconds N]           run detection on the camera, print FPS and face count, save last frame
  enroll  --id ID [--seconds N]   capture a template for ID from the camera -> ~/envlab/templates/ID.json
  verify  --id ID [--seconds N]   compare the live face against ID's template; exit 0 on match, 2 on no match
  compare --id A --id2 B          cosine score between two stored templates (sanity check)

Template file: 128-d float32 unit-norm embedding plus an int8-quantized copy (128 bytes) with its scale,
which is the form that fits on a MIFARE Classic 1K card later. Match rule: cosine >= 0.363, the
OpenCV reference threshold for SFace.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np

ROOT = Path.home() / "envlab"
MODELS = ROOT / "models"
TEMPLATES = ROOT / "templates"
OUT = ROOT / "out"

COS_THRESH = 0.363      # OpenCV SFace reference: cosine similarity >= 0.363 means same person
DET_SCORE = 0.85        # YuNet confidence floor
W, H = 640, 480         # camera stream size; YuNet is trained for faces roughly 10-300 px


# ---------------------------------------------------------------- models and math

def load_models(w=W, h=H):
    det = cv2.FaceDetectorYN.create(str(MODELS / "yunet.onnx"), "", (w, h), DET_SCORE, 0.3, 5000)
    rec = cv2.FaceRecognizerSF.create(str(MODELS / "sface.onnx"), "")
    return det, rec


def detect(det, img):
    """Returns an (N, 15) array: x, y, w, h, 5 landmark (x, y) pairs, score. N may be 0."""
    h, w = img.shape[:2]
    det.setInputSize((w, h))
    _, faces = det.detect(img)
    return faces if faces is not None else np.zeros((0, 15), np.float32)


def embed(rec, img, face):
    """128-d unit-norm SFace embedding for one detected face row."""
    aligned = rec.alignCrop(img, face)
    feat = rec.feature(aligned).reshape(-1).astype(np.float32)
    n = np.linalg.norm(feat)
    return feat / n if n > 0 else feat


def quantize(feat):
    scale = float(np.max(np.abs(feat))) or 1.0
    q = np.clip(np.round(feat / scale * 127.0), -127, 127).astype(np.int8)
    return q, scale


def dequantize(q, scale):
    f = np.asarray(q, np.float32) / 127.0 * scale
    n = np.linalg.norm(f)
    return f / n if n > 0 else f


def cosine(a, b):
    return float(np.dot(a, b))  # both unit norm


def largest(faces):
    if len(faces) == 0:
        return None
    return faces[int(np.argmax(faces[:, 2] * faces[:, 3]))]


def shrink(img, max_w=1280):
    """YuNet misses faces larger than ~300 px; a 4608-wide still needs downscaling first."""
    h, w = img.shape[:2]
    if w <= max_w:
        return img
    s = max_w / w
    return cv2.resize(img, (max_w, int(h * s)), interpolation=cv2.INTER_AREA)


def draw(img, faces):
    for f in faces:
        x, y, w, h = [int(v) for v in f[:4]]
        cv2.rectangle(img, (x, y), (x + w, y + h), (0, 255, 0), 2)
        for i in range(5):
            cv2.circle(img, (int(f[4 + 2 * i]), int(f[5 + 2 * i])), 2, (0, 0, 255), -1)
        cv2.putText(img, f"{f[14]:.2f}", (x, max(12, y - 5)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    return img


# ---------------------------------------------------------------- camera

class Camera:
    def __init__(self, w=W, h=H):
        from picamera2 import Picamera2
        self.cam = Picamera2()
        # libcamera's "RGB888" is B,G,R in memory, which is exactly what OpenCV expects.
        cfg = self.cam.create_video_configuration(main={"size": (w, h), "format": "RGB888"})
        self.cam.configure(cfg)
        try:
            from libcamera import controls
            self.cam.set_controls({"AfMode": controls.AfModeEnum.Continuous})
        except Exception as e:  # autofocus is a nicety, not a requirement
            print(f"[warn] continuous autofocus not enabled: {e}", file=sys.stderr)
        self.cam.start()
        time.sleep(1.0)  # let exposure and focus settle

    def frame(self):
        return self.cam.capture_array()

    def close(self):
        self.cam.stop()


# ---------------------------------------------------------------- templates

def template_path(uid):
    return TEMPLATES / f"{uid}.json"


def save_template(uid, feat, n_frames):
    q, scale = quantize(feat)
    TEMPLATES.mkdir(parents=True, exist_ok=True)
    data = {
        "id": uid,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "frames": n_frames,
        "model": "sface_2021dec",
        "dim": int(feat.shape[0]),
        "feat": [round(float(v), 6) for v in feat],
        "q_int8": [int(v) for v in q],
        "q_scale": scale,
        "q_roundtrip_cosine": cosine(feat, dequantize(q, scale)),
    }
    template_path(uid).write_text(json.dumps(data))
    return data


def load_template(uid):
    p = template_path(uid)
    if not p.exists():
        sys.exit(f"no template for '{uid}' at {p}; run enroll first")
    d = json.loads(p.read_text())
    return np.array(d["feat"], np.float32), d


# ---------------------------------------------------------------- commands

def cmd_test(args, det, rec):
    img = cv2.imread(args.image)
    if img is None:
        sys.exit(f"cannot read {args.image}")
    img = shrink(img)
    t0 = time.time()
    faces = detect(det, img)
    dt = time.time() - t0
    print(f"{len(faces)} face(s) in {dt * 1000:.1f} ms at {img.shape[1]}x{img.shape[0]}")
    for i, f in enumerate(faces):
        t1 = time.time()
        feat = embed(rec, img, f)
        print(f"  face {i}: box={[int(v) for v in f[:4]]} score={f[14]:.3f} "
              f"embed={1000 * (time.time() - t1):.1f} ms norm={np.linalg.norm(feat):.3f}")
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / (Path(args.image).stem + "_faces.jpg")
    cv2.imwrite(str(out), draw(img, faces))
    print(f"annotated -> {out}")


def cmd_live(args, det, rec):
    cam = Camera()
    n, t0, last = 0, time.time(), None
    try:
        while time.time() - t0 < args.seconds:
            img = cam.frame()
            faces = detect(det, img)
            n += 1
            last = (img, faces)
            if n % 10 == 0:
                print(f"frame {n}: {len(faces)} face(s), {n / (time.time() - t0):.1f} fps")
    finally:
        cam.close()
    if last is not None:
        OUT.mkdir(parents=True, exist_ok=True)
        p = OUT / "live_last.jpg"
        cv2.imwrite(str(p), draw(*last))
        print(f"saved {p}")


def cmd_enroll(args, det, rec):
    cam = Camera()
    feats, t0, n = [], time.time(), 0
    print(f"enrolling '{args.id}': look at the camera for {args.seconds:g}s")
    try:
        while time.time() - t0 < args.seconds:
            img = cam.frame()
            faces = detect(det, img)
            n += 1
            if len(faces) != 1:      # exactly one face per frame, or the frame is discarded
                continue
            feats.append(embed(rec, img, faces[0]))
    finally:
        cam.close()
    if len(feats) < 5:
        sys.exit(f"only {len(feats)} usable frames of {n}; improve light or framing and retry")
    mean = np.mean(feats, axis=0)
    mean /= np.linalg.norm(mean)
    spread = [cosine(mean, f) for f in feats]
    d = save_template(args.id, mean, len(feats))
    print(f"saved {template_path(args.id)}: {len(feats)} usable frames of {n}, "
          f"self-consistency min={min(spread):.3f} mean={np.mean(spread):.3f}, "
          f"int8 round-trip cosine={d['q_roundtrip_cosine']:.4f}")


def cmd_verify(args, det, rec):
    ref, _ = load_template(args.id)
    cam = Camera()
    best, t0, n, seen = -1.0, time.time(), 0, 0
    try:
        while time.time() - t0 < args.seconds:
            img = cam.frame()
            faces = detect(det, img)
            n += 1
            f = largest(faces)
            if f is None:
                continue
            seen += 1
            s = cosine(ref, embed(rec, img, f))
            best = max(best, s)
            if args.early and s >= COS_THRESH:
                break
    finally:
        cam.close()
    ok = best >= COS_THRESH
    print(f"id={args.id} frames={n} with_face={seen} best_cosine={best:.3f} "
          f"threshold={COS_THRESH} -> {'MATCH' if ok else 'NO MATCH'}")
    print(json.dumps({"id": args.id, "match": ok, "score": round(best, 4), "frames": n, "with_face": seen}))
    sys.exit(0 if ok else 2)


def cmd_compare(args, det, rec):
    a, _ = load_template(args.id)
    b, _ = load_template(args.id2)
    print(f"cosine({args.id}, {args.id2}) = {cosine(a, b):.3f}  (same person if >= {COS_THRESH})")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("test");    s.add_argument("--image", required=True)
    s = sub.add_parser("live");    s.add_argument("--seconds", type=float, default=10)
    s = sub.add_parser("enroll");  s.add_argument("--id", required=True); s.add_argument("--seconds", type=float, default=4)
    s = sub.add_parser("verify");  s.add_argument("--id", required=True); s.add_argument("--seconds", type=float, default=5)
    s.add_argument("--early", action="store_true", help="stop at the first frame that matches")
    s = sub.add_parser("compare"); s.add_argument("--id", required=True); s.add_argument("--id2", required=True)
    args = p.parse_args()
    det, rec = load_models()
    {"test": cmd_test, "live": cmd_live, "enroll": cmd_enroll,
     "verify": cmd_verify, "compare": cmd_compare}[args.cmd](args, det, rec)


if __name__ == "__main__":
    main()
