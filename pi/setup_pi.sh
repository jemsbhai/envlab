#!/usr/bin/env bash
# setup_pi.sh: face-recognition environment for Raspberry Pi 5 + Camera Module 3.
# Works on Pi OS Bookworm (OpenCV 4.6 in apt -> creates a venv with a newer wheel)
# and Pi OS Trixie (OpenCV 4.10 in apt -> uses system Python directly).
# Idempotent: safe to re-run. Takes 2-6 minutes the first time.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROOT="$HOME/envlab"
MODELS="$ROOT/models"
mkdir -p "$MODELS" "$ROOT/templates" "$ROOT/out"

echo "== apt packages"
sudo apt-get update -qq
sudo apt-get install -y -qq python3-picamera2 python3-opencv python3-numpy python3-venv curl

PY=python3
SYS_CV=$($PY -c "import cv2; print(cv2.__version__)" 2>/dev/null || echo "0.0.0")
echo "system OpenCV: $SYS_CV"

need_venv=0
$PY - <<EOF || need_venv=1
import sys
v = tuple(int(x) for x in "$SYS_CV".split(".")[:2])
sys.exit(0 if v >= (4, 8) else 1)
EOF

if [ "$need_venv" = "1" ]; then
  echo "== system OpenCV is older than 4.8 (YuNet 2023 model needs 4.8+); building venv"
  if [ ! -x "$ROOT/venv/bin/python" ]; then
    $PY -m venv --system-site-packages "$ROOT/venv"
  fi
  "$ROOT/venv/bin/pip" install -q --upgrade pip
  # numpy<2 keeps the apt-built picamera2 helpers (simplejpeg etc.) importable inside the venv
  "$ROOT/venv/bin/pip" install -q "numpy<2" "opencv-python-headless>=4.8,<4.11"
  PY="$ROOT/venv/bin/python"
fi
echo "python interpreter: $PY"
$PY -c "import cv2, numpy, picamera2; print('cv2', cv2.__version__, '| numpy', numpy.__version__, '| picamera2 import OK')"

echo "== models (OpenCV Zoo: YuNet detector, SFace recognizer)"
fetch() {  # name primary_url fallback_url min_bytes
  local out="$MODELS/$1" url="$2" alt="$3" min="$4" sz
  if [ -f "$out" ] && [ "$(stat -c %s "$out")" -ge "$min" ]; then echo "have $1"; return; fi
  curl -fL --retry 3 -o "$out" "$url"
  sz=$(stat -c %s "$out")
  if [ "$sz" -lt "$min" ]; then
    echo "!! $1 is only $sz bytes (Git LFS pointer?); retrying via media.githubusercontent.com"
    curl -fL --retry 3 -o "$out" "$alt"
    sz=$(stat -c %s "$out")
    [ "$sz" -ge "$min" ] || { echo "!! $1 still $sz bytes; download it by hand and re-run"; exit 1; }
  fi
  echo "fetched $1 ($sz bytes)"
}
fetch yunet.onnx \
  https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx \
  https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx \
  100000
fetch sface.onnx \
  https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx \
  https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx \
  30000000

echo "== smoke test: load both models"
$PY - <<EOF
import cv2
cv2.FaceDetectorYN.create("$MODELS/yunet.onnx", "", (320, 320))
cv2.FaceRecognizerSF.create("$MODELS/sface.onnx", "")
print("both models load OK")
EOF

# wrapper so the rest of the project never has to know which interpreter won
cat > "$ROOT/fk" <<EOF
#!/usr/bin/env bash
exec "$PY" "\$HOME/envlab/facekit.py" "\$@"
EOF
chmod +x "$ROOT/fk"
echo "$PY" > "$ROOT/.python"
echo "== done. Use: ~/envlab/fk <test|live|enroll|verify|compare> ..."
