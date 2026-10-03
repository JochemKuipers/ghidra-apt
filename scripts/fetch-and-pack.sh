#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-${ROOT}/out}"
WORKDIR="${WORKDIR:-${ROOT}/.work}"
UPSTREAM_REPO="${UPSTREAM_REPO:-NationalSecurityAgency/ghidra}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
DEBIAN_REVISION="${DEBIAN_REVISION:-1}"

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

# Prefer digest from GitHub API; fall back to SHA-256 in release body.
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
inner="${inners[0]}"

if [[ ! -x "${inner}/ghidraRun" ]]; then
  echo "missing ghidraRun in ${inner}" >&2
  exit 1
fi

staging="${WORKDIR}/staging"
mkdir -p "${staging}/opt/ghidra"
mkdir -p "${staging}/usr/bin"
mkdir -p "${staging}/usr/share/applications"
mkdir -p "${staging}/DEBIAN"

# Move contents (not the versioned folder name) into /opt/ghidra.
shopt -s dotglob
mv "${inner}"/* "${staging}/opt/ghidra/"
shopt -u dotglob

cat > "${staging}/usr/bin/ghidra" <<'EOF'
#!/bin/sh
exec /opt/ghidra/ghidraRun "$@"
EOF
chmod 755 "${staging}/usr/bin/ghidra"
chmod 755 "${staging}/opt/ghidra/ghidraRun"

# Prefer PNG icons if present; fall back to support/ghidra.ico.
icon_path="/opt/ghidra/support/ghidra.ico"
if [[ -f "${staging}/opt/ghidra/docs/images/GHIDRA_1.png" ]]; then
  icon_path="/opt/ghidra/docs/images/GHIDRA_1.png"
elif [[ -f "${staging}/opt/ghidra/docs/GhidraClass/Beginner/Images/GhidraLogo64.png" ]]; then
  icon_path="/opt/ghidra/docs/GhidraClass/Beginner/Images/GhidraLogo64.png"
fi

cat > "${staging}/usr/share/applications/ghidra.desktop" <<EOF
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

installed_size="$(du -sk "${staging}/opt" "${staging}/usr" | awk '{ s += $1 } END { print s }')"

cat > "${staging}/DEBIAN/control" <<EOF
Package: ghidra
Version: ${DEB_VERSION}
Section: devel
Priority: optional
Architecture: amd64
Maintainer: Jochem Kuipers <jochem@kuipers.cc>
Installed-Size: ${installed_size}
Depends: openjdk-21-jdk | openjdk-21-jre, python3, bash, libgtk-3-0 | libgtk-3-0t64
Homepage: https://github.com/NationalSecurityAgency/ghidra
Description: NSA Ghidra software reverse engineering framework (unofficial)
 Unofficial Debian package of Ghidra, the software reverse engineering
 (SRE) framework from the National Security Agency Research Directorate.
 .
 Includes disassembly, decompilation, graphing, and scripting. Repacked
 from the official PUBLIC release zip; not affiliated with the NSA.
 .
 Upstream: https://github.com/NationalSecurityAgency/ghidra
EOF

out_deb="${OUT}/ghidra_${DEB_VERSION}_amd64.deb"
# xz compression keeps the ~550MB artifact manageable for GitHub Releases / Pages.
dpkg-deb -Zxz -b "${staging}" "${out_deb}"

printf '%s\n' "${VERSION}" > "${OUT}/version.txt"
printf '%s\n' "${UPSTREAM_TAG}" > "${OUT}/upstream-tag.txt"

echo "Wrote ${out_deb}"
ls -lh "${OUT}"/*.deb
