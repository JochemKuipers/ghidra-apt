#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-${ROOT}/out}"
WORKDIR="${WORKDIR:-${ROOT}/.work}"
UPSTREAM_REPO="${UPSTREAM_REPO:-NationalSecurityAgency/ghidra}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
DEBIAN_REVISION="${DEBIAN_REVISION:-1}"
# GitHub rejects git blobs over 100 MiB (gh-pages pool). Keep each .deb under this.
MAX_DEB_BYTES="${MAX_DEB_BYTES:-$((100 * 1024 * 1024))}"

mkdir -p "${OUT}" "${WORKDIR}"
rm -rf "${OUT:?}"/* "${WORKDIR:?}"/*

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need gh
need sha256sum
need unzip
need dpkg-deb
need rsync

if [[ -z "${UPSTREAM_TAG}" ]]; then
  UPSTREAM_TAG="$(gh release view -R "${UPSTREAM_REPO}" --json tagName -q .tagName)"
fi

echo "Upstream tag: ${UPSTREAM_TAG}"

# Version from tag: Ghidra_12.1.4_build -> 12.1.4
VERSION="$(printf '%s\n' "${UPSTREAM_TAG}" | sed -E 's/^Ghidra_//; s/_build$//; s/^v//')"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.+~].*)?$ ]]; then
  echo "could not parse upstream version from tag: ${UPSTREAM_TAG}" >&2
  exit 1
fi
DEB_VERSION="${VERSION}-${DEBIAN_REVISION}"

download_dir="${WORKDIR}/download"
mkdir -p "${download_dir}"

gh release download -R "${UPSTREAM_REPO}" "${UPSTREAM_TAG}" \
  --pattern 'ghidra_*_PUBLIC_*.zip' \
  -D "${download_dir}" --clobber

shopt -s nullglob
zips=("${download_dir}"/ghidra_*_PUBLIC_*.zip)
if (( ${#zips[@]} != 1 )); then
  echo "expected exactly one PUBLIC zip, found ${#zips[@]}" >&2
  ls -la "${download_dir}" >&2 || true
  exit 1
fi
zip_file="${zips[0]}"
zip_base="$(basename "${zip_file}")"

expected="$(
  gh release view -R "${UPSTREAM_REPO}" "${UPSTREAM_TAG}" --json assets \
    -q ".assets[] | select(.name == \"${zip_base}\") | .digest" \
    | sed 's/^sha256://'
)"
if [[ -z "${expected}" ]]; then
  body="$(gh release view -R "${UPSTREAM_REPO}" "${UPSTREAM_TAG}" --json body -q .body)"
  expected="$(printf '%s\n' "${body}" | sed -nE 's/.*SHA-256:[[:space:]]*`([a-f0-9]{64})`.*/\1/ip')"
fi
if [[ -z "${expected}" ]]; then
  echo "could not determine expected SHA-256 for ${zip_base}" >&2
  exit 1
fi

actual="$(sha256sum "${zip_file}" | awk '{ print $1 }')"
if [[ "${actual}" != "${expected}" ]]; then
  echo "SHA256 mismatch for ${zip_base}" >&2
  echo "  expected: ${expected}" >&2
  echo "  actual:   ${actual}" >&2
  exit 1
fi
echo "SHA256 OK: ${zip_base}"

extract_dir="${WORKDIR}/extract"
mkdir -p "${extract_dir}"
unzip -q "${zip_file}" -d "${extract_dir}"

inners=()
while IFS= read -r -d '' dir; do
  inners+=("${dir}")
done < <(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d -print0)

if (( ${#inners[@]} != 1 )); then
  echo "expected exactly one top-level directory in zip, found ${#inners[@]}" >&2
  ls -la "${extract_dir}" >&2 || true
  exit 1
fi
SRC="${inners[0]}"

if [[ ! -x "${SRC}/ghidraRun" ]]; then
  echo "missing ghidraRun in ${SRC}" >&2
  exit 1
fi

# Prefer PNG icons if present; fall back to support/ghidra.ico.
icon_path="/opt/ghidra/support/ghidra.ico"
if [[ -f "${SRC}/docs/images/GHIDRA_1.png" ]]; then
  icon_path="/opt/ghidra/docs/images/GHIDRA_1.png"
elif [[ -f "${SRC}/docs/GhidraClass/Beginner/Images/GhidraLogo64.png" ]]; then
  icon_path="/opt/ghidra/docs/GhidraClass/Beginner/Images/GhidraLogo64.png"
fi

DATA_PACKAGES=(
  ghidra-base
  ghidra-functionid
  ghidra-bsim
  ghidra-features
  ghidra-debug
  ghidra-framework
  ghidra-docs
  ghidra-extensions
  ghidra-jython
)
depends_list="openjdk-21-jdk | openjdk-21-jre, python3, bash, libgtk-3-0 | libgtk-3-0t64"
for pkg in "${DATA_PACKAGES[@]}"; do
  depends_list+=", ${pkg} (= ${DEB_VERSION})"
done

build_deb() {
  local pkg="$1"
  local desc="$2"
  local staging="$3"
  shift 3
  # remaining args: extra Depends fields (optional single string)
  local extra_depends="${1:-}"

  mkdir -p "${staging}/DEBIAN"

  local installed_size
  installed_size="$(du -sk "${staging}" --exclude=DEBIAN 2>/dev/null | awk '{ print $1 }')"
  if [[ -z "${installed_size}" ]]; then
    installed_size=0
  fi

  {
    echo "Package: ${pkg}"
    echo "Version: ${DEB_VERSION}"
    echo "Section: devel"
    echo "Priority: optional"
    echo "Architecture: amd64"
    echo "Maintainer: Jochem Kuipers <jochem@kuipers.cc>"
    echo "Installed-Size: ${installed_size}"
    if [[ -n "${extra_depends}" ]]; then
      echo "Depends: ${extra_depends}"
    fi
    echo "Homepage: https://github.com/NationalSecurityAgency/ghidra"
    echo "Description: ${desc}"
    if [[ "${pkg}" == "ghidra" ]]; then
      cat <<'EOF'
 Unofficial Debian packaging of Ghidra, the software reverse engineering
 (SRE) framework from the National Security Agency Research Directorate.
 .
 Split into several .deb parts so each stays under GitHub's 100 MiB
 git limit for the apt-repo Pages pool. Install with: apt install ghidra
 .
 Upstream: https://github.com/NationalSecurityAgency/ghidra
EOF
    else
      cat <<EOF
 Data package for unofficial Ghidra ${VERSION} (${pkg}).
 .
 Pulled in automatically by the ghidra metapackage; not meant to be
 installed alone.
EOF
    fi
  } > "${staging}/DEBIAN/control"

  local out_deb="${OUT}/${pkg}_${DEB_VERSION}_amd64.deb"
  dpkg-deb --root-owner-group -Zxz -b "${staging}" "${out_deb}"

  local size
  size="$(stat -c '%s' "${out_deb}")"
  if (( size >= MAX_DEB_BYTES )); then
    echo "ERROR: ${out_deb} is ${size} bytes (>= ${MAX_DEB_BYTES}); exceeds GitHub git limit" >&2
    exit 1
  fi
  echo "Wrote ${out_deb} ($(( size / 1024 / 1024 )) MiB)"
}

stage_paths() {
  local staging="$1"
  shift
  local rel
  for rel in "$@"; do
    local src="${SRC}/${rel}"
    if [[ ! -e "${src}" ]]; then
      echo "missing path in upstream tree: ${rel}" >&2
      exit 1
    fi
    local dest="${staging}/opt/ghidra/$(dirname "${rel}")"
    mkdir -p "${dest}"
    cp -a "${src}" "${dest}/"
  done
}

# --- data packages (paths relative to upstream root) ---

s="${WORKDIR}/stage-ghidra-base"
rm -rf "${s}"
stage_paths "${s}" Ghidra/Features/Base
build_deb ghidra-base "Ghidra Base feature data (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-functionid"
rm -rf "${s}"
stage_paths "${s}" Ghidra/Features/FunctionID
build_deb ghidra-functionid "Ghidra FunctionID data (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-bsim"
rm -rf "${s}"
stage_paths "${s}" Ghidra/Features/BSim
build_deb ghidra-bsim "Ghidra BSim feature data (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-features"
rm -rf "${s}"
mkdir -p "${s}/opt/ghidra/Ghidra/Features"
rsync -a \
  --exclude Base \
  --exclude FunctionID \
  --exclude BSim \
  "${SRC}/Ghidra/Features/" "${s}/opt/ghidra/Ghidra/Features/"
build_deb ghidra-features "Ghidra remaining Features data (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-debug"
rm -rf "${s}"
stage_paths "${s}" Ghidra/Debug
build_deb ghidra-debug "Ghidra Debug components (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-framework"
rm -rf "${s}"
stage_paths "${s}" \
  Ghidra/Framework \
  Ghidra/Processors \
  Ghidra/Configurations \
  Ghidra/application.properties \
  Ghidra/patch
# empty Extensions placeholder used by upstream layout
mkdir -p "${s}/opt/ghidra/Ghidra/Extensions"
build_deb ghidra-framework "Ghidra Framework and Processors (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-docs"
rm -rf "${s}"
stage_paths "${s}" docs
build_deb ghidra-docs "Ghidra documentation (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-jython"
rm -rf "${s}"
mkdir -p "${s}/opt/ghidra/Extensions/Ghidra"
shopt -s nullglob
jython_zips=("${SRC}/Extensions/Ghidra/"*Jython.zip)
if (( ${#jython_zips[@]} != 1 )); then
  echo "expected exactly one Jython extension zip, found ${#jython_zips[@]}" >&2
  exit 1
fi
cp -a "${jython_zips[0]}" "${s}/opt/ghidra/Extensions/Ghidra/"
shopt -u nullglob
build_deb ghidra-jython "Ghidra Jython extension (unofficial)" "${s}"

s="${WORKDIR}/stage-ghidra-extensions"
rm -rf "${s}"
mkdir -p "${s}/opt/ghidra/Extensions"
rsync -a --exclude '*Jython.zip' "${SRC}/Extensions/" "${s}/opt/ghidra/Extensions/"
build_deb ghidra-extensions "Ghidra bundled extensions (unofficial)" "${s}"

# --- main package: launcher + small runtime bits ---
s="${WORKDIR}/stage-ghidra"
rm -rf "${s}"
mkdir -p "${s}/opt/ghidra" "${s}/usr/bin" "${s}/usr/share/applications"
for rel in GPL support licenses server bom.json docker \
  GettingStarted.html GettingStarted.md LICENSE ghidraRun ghidraRun.bat; do
  if [[ -e "${SRC}/${rel}" ]]; then
    cp -a "${SRC}/${rel}" "${s}/opt/ghidra/"
  fi
done
chmod 755 "${s}/opt/ghidra/ghidraRun"

cat > "${s}/usr/bin/ghidra" <<'EOF'
#!/bin/sh
exec /opt/ghidra/ghidraRun "$@"
EOF
chmod 755 "${s}/usr/bin/ghidra"

cat > "${s}/usr/share/applications/ghidra.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Ghidra
Comment=NSA Software Reverse Engineering Framework
Exec=/usr/bin/ghidra
Icon=${icon_path}
Terminal=false
Categories=Development;Debugger;
Keywords=reverse;engineering;disassembler;decompiler;
StartupWMClass=ghidra-Ghidra
EOF

build_deb ghidra "NSA Ghidra software reverse engineering framework (unofficial)" "${s}" "${depends_list}"

printf '%s\n' "${VERSION}" > "${OUT}/version.txt"
printf '%s\n' "${UPSTREAM_TAG}" > "${OUT}/upstream-tag.txt"

echo "Built packages:"
ls -lh "${OUT}"/*.deb
