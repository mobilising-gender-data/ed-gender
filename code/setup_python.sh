#!/usr/bin/env bash
# =============================================================================
# setup_python.sh — build the venv that 02_places.py and 03_howde.py need
#
# Run once, from the project root:   bash code/setup_python.sh
#
# Every step here exists because the obvious version of it fails on this
# machine. All five problems below were hit and diagnosed on 2026-08-09; none
# are guesses. If you are setting this up elsewhere, re-check them rather than
# assuming.
#
#   1. PYTHON 3.10, NOT 3.14. The system python is 3.14. infostop 0.1.9 (the
#      current release, from 2021) does not build against it. 3.10 is already
#      installed at /usr/bin/python3.10 and works.
#
#   2. NOT SYSTEM-WIDE. Arch enforces PEP 668, so `pip install` into the system
#      python is refused outright. A venv is mandatory, not tidiness.
#
#   3. pybind11 AND setuptools<81 MUST BE PRESENT BEFORE infostop.
#      infostop needs pybind11 to compile, and its pinned old `infomap`
#      needs `pkg_resources`, which setuptools >=81 removed.
#
#   4. --no-build-isolation FOR infostop. With isolation, pip builds in a
#      fresh environment with modern setuptools and step 3 is undone, so the
#      pkg_resources failure comes back no matter what the venv contains.
#
#   5. JAVA 17, NOT 26. HoWDe runs on PySpark; the default JDK here is 26 and
#      Spark 4.2 dies on it with ClassNotFoundException: jdk.internal.ref.Cleaner.
#      java-17-openjdk is installed. See env.sh, written at the end of this
#      script — source it before running anything that touches HoWDe.
# =============================================================================
set -euo pipefail

VENV="${VENV:-.venv-ed}"

# --- ON AN HPC / SHARED CLUSTER -----------------------------------------------
# Rocky Linux 9 (and RHEL 9 generally) ships python3.9 as the system Python and
# offers 3.11 / 3.12 as packages — but NOT 3.10, and you will not have root to
# install anything anyway. Two things follow:
#
#   * Get 3.10 from a module or from conda, not from dnf. If neither is
#     available, 3.11 is the next thing to try; infostop 0.1.9 is only
#     CONFIRMED on 3.10 here, so treat 3.11 as untested rather than safe.
#
#       module avail python           # see what the cluster offers
#       module load python/3.10       # names vary: python/3.10.x, Python/3.10
#       # or
#       conda create -y -n ed python=3.10 && conda activate ed
#
#   * RUN THIS SCRIPT ON A LOGIN NODE. Compute nodes on most clusters have no
#     outbound internet, so pip cannot reach PyPI from inside a batch job.
#     Build the venv on the login node, then use it from the job.
#
# Override the search with PY=/path/to/python3.10 if it picks wrong.

find_python() {
  [ -n "${PY:-}" ] && { echo "$PY"; return; }
  # An active conda/venv first — if the user loaded a module or activated an
  # environment, that is almost certainly the intended interpreter.
  if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/python" ]; then
    v="$("$CONDA_PREFIX/bin/python" -c 'import sys;print("%d%d"%sys.version_info[:2])')"
    [ "$v" -ge 310 ] && [ "$v" -le 312 ] && { echo "$CONDA_PREFIX/bin/python"; return; }
  fi
  for c in python3.10 python3.11 python3.12; do
    p="$(command -v "$c" 2>/dev/null)" && [ -n "$p" ] && { echo "$p"; return; }
  done
  for p in /usr/bin/python3.1[012] /usr/local/bin/python3.1[012] \
           /opt/homebrew/bin/python3.1[012]; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
}
PY310="$(find_python)"
if [ -z "$PY310" ]; then
  echo "ERROR: no python3.10-3.12 found."
  echo "  infostop does not build on 3.13+."
  echo
  echo "  On an HPC (no root):"
  echo "    module avail python                 # then e.g. module load python/3.10"
  echo "    conda create -y -n ed python=3.10 && conda activate ed"
  echo
  echo "  With root:"
  echo "    Debian/Ubuntu : sudo apt install python3.10 python3.10-venv"
  echo "    Rocky/RHEL 9  : sudo dnf install python3.11   # 3.10 is not packaged"
  echo
  echo "  Then re-run, or set PY=/path/to/python3.10"
  exit 1
fi
case "$("$PY310" -c 'import sys;print("%d.%d"%sys.version_info[:2])')" in
  3.10) ;;
  *) echo "WARNING: using $PY310 — only 3.10 is confirmed to build infostop." ;;
esac

# --- locate a JDK 17 ----------------------------------------------------------
# Spark 4.2 cannot start on JDK 26 (ClassNotFoundException:
# jdk.internal.ref.Cleaner). 17 and 21 are both supported by Spark 4.x.
find_jdk() {
  [ -n "${JDK:-}" ] && { echo "$JDK"; return; }
  # A module-loaded JDK exports JAVA_HOME; trust it if it is 17 or 21.
  if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
    case "$("${JAVA_HOME}/bin/java" -version 2>&1 | head -1)" in
      *\"17*|*\"21*) echo "$JAVA_HOME"; return ;;
    esac
  fi
  for p in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-17-openjdk-amd64 \
           /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-21-openjdk-amd64 \
           /usr/lib/jvm/temurin-17-jdk /usr/lib/jvm/temurin-21-jdk \
           /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home; do
    [ -d "$p" ] && { echo "$p"; return; }
  done
  for p in /usr/lib/jvm/*17* /usr/lib/jvm/*21*; do
    [ -d "$p" ] && { echo "$p"; return; }
  done
}
JDK17="$(find_jdk)"
if [ -z "$JDK17" ]; then
  echo "WARNING: no JDK 17/21 found — HoWDe (PySpark) will not start."
  echo "  On an HPC:  module avail java   then  module load java/17"
  echo "  With root:  sudo dnf install java-17-openjdk-devel   (Rocky 9)"
  echo "  Or set JDK=/path/to/jdk and re-run."
  echo "  Everything except 03_howde.py works without it."
  JDK17="/JDK-NOT-FOUND"
fi

echo "==> python : $PY310"
echo "==> jdk    : $JDK17"

echo "==> creating $VENV with $($PY310 --version)"
"$PY310" -m venv "$VENV"
PIP="$VENV/bin/pip"

echo "==> build prerequisites (order matters — see notes 3 and 4)"
"$PIP" install --quiet --upgrade pip wheel
"$PIP" install --quiet "setuptools<81" pybind11

echo "==> infostop (no build isolation)"
"$PIP" install --no-build-isolation infostop

echo "==> HoWDe, and the glue"
"$PIP" install --quiet HoWDe pandas pyarrow h3

echo "==> writing code/env.sh"
cat > code/env.sh <<EOF
# Source before running the Python steps:  source code/env.sh
export JAVA_HOME="$JDK17"
export PYSPARK_PYTHON="\$PWD/$VENV/bin/python"
export PYSPARK_DRIVER_PYTHON="\$PWD/$VENV/bin/python"
export PATH="\$PWD/$VENV/bin:\$PATH"
EOF

echo
echo "==> verifying"
# shellcheck disable=SC1091
source code/env.sh
"$VENV/bin/python" - <<'PYEOF'
import numpy as np, h3
from infostop import SpatialInfomap
pts = np.vstack([p + np.random.default_rng(0).normal(0, 3e-4, (50, 2))
                 for p in np.array([[55.95, -3.20], [55.96, -3.21]])])
lab = SpatialInfomap(r2=50, label_singleton=True).fit_predict(pts)
assert len(set(lab.tolist())) == 2, lab
print("  infostop OK  ->", len(set(lab.tolist())), "places from 2 true clusters")
print("  h3 OK        ->", h3.latlng_to_cell(55.95, -3.20, 9))
PYEOF

"$VENV/bin/python" - <<'PYEOF' 2>/dev/null
from pyspark.sql import SparkSession
import howde
s = SparkSession.builder.master("local[1]").getOrCreate()
s.sparkContext.setLogLevel("ERROR")
n = s.createDataFrame([(1, "a")], ["x", "y"]).count()
s.stop()
print("  pyspark OK   -> spark started, rows:", n)
print("  howde OK     -> HoWDe_labelling present:", hasattr(howde, "HoWDe_labelling"))
PYEOF

echo
echo "Done. Before each session:   source code/env.sh"
