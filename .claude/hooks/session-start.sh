#!/bin/bash
# SessionStart hook for Claude Code cloud sessions.
#
# Builds the full EdelweissFE toolchain (conda env + Eigen + autodiff + Fastor + Marmot)
# and then EdelweissFE itself, mirroring .github/workflows/run_tests.yml.
#
# Every step leaves a marker file behind, so re-running the hook only redoes what is
# missing. The container is cached after the hook completes, so the expensive
# Marmot build normally happens only once.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

EW_ROOT="${EW_ROOT:-/opt/edelweiss}"
CONDA_DIR="$EW_ROOT/miniforge3"
ENV_NAME="ewfe"
ENV_DIR="$CONDA_DIR/envs/$ENV_NAME"
SRC_DIR="$EW_ROOT/src"
MARKERS="$EW_ROOT/.done"
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
NPROC="$(nproc)"

mkdir -p "$EW_ROOT" "$SRC_DIR" "$MARKERS"
log() { echo "[edelweiss-setup] $*" >&2; }

# 1) Miniforge
if [ ! -f "$MARKERS/miniforge" ]; then
  log "Installing Miniforge"
  rm -rf "$CONDA_DIR"
  curl -sSL -o "$EW_ROOT/miniforge.sh" \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh"
  bash "$EW_ROOT/miniforge.sh" -b -p "$CONDA_DIR"
  rm -f "$EW_ROOT/miniforge.sh"
  touch "$MARKERS/miniforge"
fi

# 2) Conda environment from requirements.txt
if [ ! -f "$MARKERS/env" ]; then
  log "Creating conda env '$ENV_NAME' from requirements.txt"
  "$CONDA_DIR/bin/mamba" create -y -n "$ENV_NAME" --file "$REPO_DIR/requirements.txt"
  touch "$MARKERS/env"
fi

export PATH="$ENV_DIR/bin:$PATH"
export CONDA_PREFIX="$ENV_DIR"

# 3) Eigen
if [ ! -f "$MARKERS/eigen" ]; then
  log "Installing Eigen 3.4.0"
  rm -rf "$SRC_DIR/eigen"
  git clone --depth 1 --branch 3.4.0 https://gitlab.com/libeigen/eigen.git "$SRC_DIR/eigen"
  cmake -S "$SRC_DIR/eigen" -B "$SRC_DIR/eigen/build" \
    -DBUILD_TESTING=OFF \
    -DINCLUDE_INSTALL_DIR="$CONDA_PREFIX/include" \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX"
  cmake --build "$SRC_DIR/eigen/build" --target install
  touch "$MARKERS/eigen"
fi

# 4) autodiff
if [ ! -f "$MARKERS/autodiff" ]; then
  log "Installing autodiff v1.1.0"
  rm -rf "$SRC_DIR/autodiff"
  git clone --depth 1 --branch v1.1.0 https://github.com/autodiff/autodiff.git "$SRC_DIR/autodiff"
  cmake -S "$SRC_DIR/autodiff" -B "$SRC_DIR/autodiff/build" \
    -DAUTODIFF_BUILD_TESTS=OFF \
    -DAUTODIFF_BUILD_PYTHON=OFF \
    -DAUTODIFF_BUILD_EXAMPLES=OFF \
    -DAUTODIFF_BUILD_DOCS=OFF \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX"
  cmake --build "$SRC_DIR/autodiff/build" --target install
  touch "$MARKERS/autodiff"
fi

# 5) Fastor
if [ ! -f "$MARKERS/fastor" ]; then
  log "Installing Fastor"
  rm -rf "$SRC_DIR/Fastor"
  git clone --depth 1 https://github.com/romeric/Fastor.git "$SRC_DIR/Fastor"
  cmake -S "$SRC_DIR/Fastor" -B "$SRC_DIR/Fastor/build" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX"
  cmake --build "$SRC_DIR/Fastor/build" --target install
  touch "$MARKERS/fastor"
fi

# 6) Marmot (override MARMOT_REPO / MARMOT_BRANCH to use a fork).
#    Pinned to v25.11: newer Marmot (v26.05+) dropped Marmot/Marmot.h and the
#    MarmotLibrary factory API that this EdelweissFE version links against.
MARMOT_REPO="${MARMOT_REPO:-https://github.com/MAteRialMOdelingToolbox/Marmot.git}"
MARMOT_BRANCH="${MARMOT_BRANCH:-v25.11}"
if [ ! -f "$MARKERS/marmot" ]; then
  log "Building Marmot from $MARMOT_REPO ${MARMOT_BRANCH:+(branch $MARMOT_BRANCH)}"
  rm -rf "$SRC_DIR/Marmot"
  git clone --recurse-submodules ${MARMOT_BRANCH:+--branch "$MARMOT_BRANCH"} \
    "$MARMOT_REPO" "$SRC_DIR/Marmot"
  cmake -S "$SRC_DIR/Marmot" -B "$SRC_DIR/Marmot/build" \
    -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX"
  cmake --build "$SRC_DIR/Marmot/build" --target install -j "$NPROC"
  touch "$MARKERS/marmot"
fi

# 7) Linters used by .pre-commit-config.yaml
if [ ! -f "$MARKERS/linters" ]; then
  log "Installing linters"
  pip install -q "black==24.4.0" "isort==5.13.2" "flake8==7.0.0" "autoflake==2.3.1"
  touch "$MARKERS/linters"
fi

# 8) EdelweissFE itself, as an editable install so edits to the .py files take effect
#    immediately. Re-run every session: only changed Cython modules get recompiled.
log "Building EdelweissFE (editable)"
cd "$REPO_DIR"
export MARMOT_INSTALL_DIR="$CONDA_PREFIX"
export MKL_INCLUDE_DIR="$CONDA_PREFIX/include"
python setup.py build_ext -i -j "$NPROC" >"$EW_ROOT/build_ext.log" 2>&1 \
  || { tail -50 "$EW_ROOT/build_ext.log" >&2; exit 1; }
pip install --no-build-isolation --no-deps -e . >"$EW_ROOT/pip_install.log" 2>&1 \
  || { tail -50 "$EW_ROOT/pip_install.log" >&2; exit 1; }

# Make the environment available to every shell in this session
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$ENV_DIR/bin:\$PATH\""
    echo "export CONDA_PREFIX=\"$ENV_DIR\""
    echo "export MARMOT_INSTALL_DIR=\"$ENV_DIR\""
    echo "export MKL_INCLUDE_DIR=\"$ENV_DIR/include\""
    echo "export OMP_NUM_THREADS=\"$NPROC\""
  } >>"$CLAUDE_ENV_FILE"
fi

log "Done. Try: edelweissfe testfiles/<case>/test.inp  or  run_tests_edelweissfe testfiles/"
