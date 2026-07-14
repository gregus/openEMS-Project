#!/usr/bin/env bash
#
# Build redistributable CSXCAD/openEMS Python wheels that link against an
# existing C++ installation (e.g. ~/opt/openEMS).
#
# Unlike scripts/build_python.sh, which compiles and installs the extensions
# directly into a single venv, this script emits .whl files. The absolute
# library path of the C++ installation is baked into each extension module as
# an ELF RUNPATH, so the resulting wheels can be pip-installed into any number
# of virtual environments without setting LD_LIBRARY_PATH.
#
# The C++ installation is referenced, not vendored: the wheels stay tied to
# --cpp-install-dir. Moving or deleting that directory breaks them, and they
# are not portable to other machines (use auditwheel for that).

set -euo pipefail

function die {
  printf "%s\n" "$1"
  printf "%s\n" "See --help"
  exit 1
}

function print_help {
  printf -- "Build CSXCAD/openEMS Python wheels against an existing C++ install:\n"
  printf -- "  %s [options]\n\n" "$0"
  printf -- "  Options:\n"
  printf -- "	--cpp-install-dir DIR\tC++ install prefix to link against\n"
  printf -- "	  \t\t\t(default: \$HOME/opt/openEMS)\n"
  printf -- "	--outdir DIR\t\twhere to write the .whl files\n"
  printf -- "	  \t\t\t(default: <project>/wheelhouse)\n"
  printf -- "	--no-scm\t\tuse the static fallback_version from pyproject.toml\n"
  printf -- "	  \t\t\tinstead of deriving a version from git\n"
  printf -- "	--keep-build-venv\tdon't delete the temporary build venv on exit\n"
}

function parse_args {
  while true; do
    if [ -z ${1+x} ]; then
      break
    fi

    case $1 in
      -h|--help)
        print_help
        exit
        ;;

      --cpp-install-dir)
        if [ -z ${2+x} ] || [ -z "$2" ]; then
          die "ERROR: --cpp-install-dir is specified with an empty value!"
        fi
        CPP_INSTALL_DIR="$2"
        shift
        ;;
      --cpp-install-dir=?*)
        CPP_INSTALL_DIR=${1#*=}
        ;;
      --cpp-install-dir=)
        die "ERROR: --cpp-install-dir is specified with an empty value!"
        ;;

      --outdir)
        if [ -z ${2+x} ] || [ -z "$2" ]; then
          die "ERROR: --outdir is specified with an empty value!"
        fi
        OUTDIR="$2"
        shift
        ;;
      --outdir=?*)
        OUTDIR=${1#*=}
        ;;
      --outdir=)
        die "ERROR: --outdir is specified with an empty value!"
        ;;

      --no-scm)
        USE_SCM=0
        ;;
      --keep-build-venv)
        KEEP_BUILD_VENV=1
        ;;

      --)
        shift
        break
        ;;
      -?*)
        die "ERROR: Unknown option $1"
        ;;
      *)
        break
    esac

    shift
  done

  if [ ! -d "$CPP_INSTALL_DIR" ]; then
    die "C++ install dir $CPP_INSTALL_DIR does not exist. Build and install the
C++ libraries first (see update_openEMS.sh), or pass --cpp-install-dir."
  fi
  CPP_INSTALL_DIR=$(readlink -f "$CPP_INSTALL_DIR")

  if [ ! -f "$CPP_INSTALL_DIR/include/CSXCAD/ContinuousStructure.h" ]; then
    die "No CSXCAD headers under $CPP_INSTALL_DIR/include. Is this really the
C++ install prefix?"
  fi
}

PROJECT_DIR=$(readlink -f "$(dirname "$0")/..")

# default values
CPP_INSTALL_DIR="$HOME/opt/openEMS"
OUTDIR="$PROJECT_DIR/wheelhouse"
USE_SCM=1
KEEP_BUILD_VENV=0
PYTHON_EXT=( "CSXCAD" "openEMS" )

parse_args "$@"

mkdir -p "$OUTDIR"
OUTDIR=$(readlink -f "$OUTDIR")

BUILD_VENV=$(mktemp -d -t openems-wheel-build-XXXXXX)
function cleanup {
  if [ "$KEEP_BUILD_VENV" -eq 0 ]; then
    rm -rf "$BUILD_VENV"
  else
    printf "\nBuild venv kept at: %s\n" "$BUILD_VENV"
  fi
}
trap cleanup EXIT

echo "==> Creating build venv in $BUILD_VENV"
python3 -m venv "$BUILD_VENV"
# matplotlib is a runtime dependency of CSXCAD rather than a build tool, but the
# openEMS build backend requires CSXCAD, and "build" refuses to start until the
# full dependency closure of every build requirement is satisfied.
"$BUILD_VENV/bin/pip" install --quiet --upgrade \
  pip setuptools wheel build cython numpy h5py matplotlib

if [ "$USE_SCM" -eq 1 ]; then
  "$BUILD_VENV/bin/pip" install --quiet --upgrade "setuptools_scm>=8"
else
  # setup.py falls back to pyproject.toml's fallback_version when
  # setuptools_scm is absent from the build environment.
  export CSXCAD_NOSCM=1
  export OPENEMS_NOSCM=1
fi

echo "==> Linking against C++ install: $CPP_INSTALL_DIR"
export CSXCAD_INSTALL_PATH="$CPP_INSTALL_DIR"
export OPENEMS_INSTALL_PATH="$CPP_INSTALL_DIR"

for ext in "${PYTHON_EXT[@]}"; do
  echo "==> Building $ext wheel"

  # Stale artifacts from a previous run (or from build_python.sh) would
  # otherwise be picked up and shipped with the wrong RUNPATH.
  rm -rf "${PROJECT_DIR:?}/$ext/python/build" \
         "${PROJECT_DIR:?}/$ext/python/$ext.egg-info"

  # VIRTUAL_ENV is unset for the build itself. setup.py appends $VIRTUAL_ENV to
  # runtime_library_dirs, which would bake this throwaway build venv into the
  # RUNPATH of the shipped extension modules.
  #
  # --no-isolation makes the build see the packages installed above. For
  # openEMS that is what keeps CSXCAD a plain name in Requires-Dist: when
  # CSXCAD is importable at build time, setup.py records "CSXCAD", otherwise it
  # bakes in a "file://" URL pointing at this checkout, which would make the
  # wheel unusable anywhere else.
  (
    cd "$PROJECT_DIR/$ext/python"
    env -u VIRTUAL_ENV "$BUILD_VENV/bin/python" -m build \
      --wheel --no-isolation --outdir "$OUTDIR"
  )

  # openEMS depends on CSXCAD at build time (it cimports its .pxd files and
  # links libCSXCAD), so install each extension into the build venv as we go.
  "$BUILD_VENV/bin/pip" install --quiet --force-reinstall --no-deps \
    "$(ls -t "$OUTDIR"/"${ext,,}"-*.whl | head -1)"
done

echo
echo "==> Verifying the wheels in a throwaway venv"

# LD_LIBRARY_PATH takes precedence over DT_RUNPATH, so a developer who has
# <prefix>/lib on LD_LIBRARY_PATH (a common openEMS setup) would see even a
# completely broken wheel resolve correctly. Drop it, so that what we verify is
# the wheel itself rather than the ambient environment.
unset LD_LIBRARY_PATH

# ldd is used rather than readelf: it reports what the loader actually resolves
# each NEEDED entry to, which is the property we care about. A RUNPATH that
# merely looks right does not prove the libraries are found.
TEST_VENV="$BUILD_VENV/verify"
python3 -m venv "$TEST_VENV"
"$TEST_VENV/bin/pip" install --quiet "$OUTDIR"/*.whl

found_so=0
while IFS= read -r so; do
  found_so=1
  resolved=$(ldd "$so")

  if [[ "$resolved" == *"not found"* ]]; then
    die "ERROR: $(basename "$so") has unresolved libraries:
$(echo "$resolved" | grep 'not found')"
  fi

  # Not every extension actually links a C++ library. Utilities.pyx, for
  # instance, uses no CSXCAD symbols, so the linker's --as-needed drops
  # -lCSXCAD and the module ends up needing nothing but libc. Such a module is
  # correct either way, and has no library reference to assert on.
  cxx_deps=$(echo "$resolved" | grep -E 'libCSXCAD|libopenEMS|libnf2ff|libfparser' || true)
  if [ -z "$cxx_deps" ]; then
    printf "    ok  %-45s (no C++ deps)\n" "$(basename "$so")"
    continue
  fi

  if [[ "$cxx_deps" != *"$CPP_INSTALL_DIR/lib"* ]]; then
    die "ERROR: $(basename "$so") does not resolve to $CPP_INSTALL_DIR/lib:
$cxx_deps"
  fi
  printf "    ok  %-45s (-> %s/lib)\n" "$(basename "$so")" "$CPP_INSTALL_DIR"
done < <(find "$TEST_VENV/lib" \( -path '*/CSXCAD/*' -o -path '*/openEMS/*' \) \
              -name '*.so' 2>/dev/null)

if [ "$found_so" -eq 0 ]; then
  die "ERROR: no extension modules found in the test venv; build failed?"
fi

# Import both packages for real: a clean ldd does not prove the modules
# initialise (a missing symbol would only show up here).
"$TEST_VENV/bin/python" -c \
  "import CSXCAD, openEMS; from openEMS import openEMS as _o; print('    ok  import CSXCAD + openEMS')"

echo
echo "Wheels written to $OUTDIR:"
for whl in "$OUTDIR"/*.whl; do
  printf "    %8s  %s\n" \
    "$(du -h "$whl" | cut -f1)" "$(basename "$whl")"
done

echo
echo "Install them into any virtual environment with:"
echo
echo "    pip install $OUTDIR/*.whl"
echo

cat <<EOF
The wheels reference the C++ libraries in $CPP_INSTALL_DIR/lib
via RUNPATH; no LD_LIBRARY_PATH is needed, and rebuilding the C++ libraries is
picked up by every venv without reinstalling. Moving or deleting that directory
breaks the installed venvs.

To also get the openEMS/nf2ff command line tools on PATH inside a venv:

    ln -sf $CPP_INSTALL_DIR/bin/* "\$VIRTUAL_ENV/bin/"
EOF
