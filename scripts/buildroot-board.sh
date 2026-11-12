#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

case "${1:-}" in
  configure|build|savedefconfig|linux-update-defconfig)
    command=$1
    ;;
  *)
    echo "usage: $0 <configure|build|savedefconfig|linux-update-defconfig>" >&2
    exit 1
    ;;
esac
if (($# != 1)); then
  echo "usage: $0 <configure|build|savedefconfig|linux-update-defconfig>" >&2
  exit 1
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

: "${BOARD:?BOARD is required}"
: "${BOARD_DIR:?BOARD_DIR is required}"
: "${TPMDD_ARCH:?TPMDD_ARCH is required}"
: "${TPMDD_VERSION:?TPMDD_VERSION is required}"
: "${BUILDROOT_JOBS:?BUILDROOT_JOBS is required}"
: "${BUILDROOT_SRC_DIR:?BUILDROOT_SRC_DIR is required}"
: "${BUILDROOT_DL_DIR:?BUILDROOT_DL_DIR is required}"
: "${BUILDROOT_TARBALL:?BUILDROOT_TARBALL is required}"
: "${BUILDROOT_HASH:?BUILDROOT_HASH is required}"
: "${BUILDROOT_PATCH:?BUILDROOT_PATCH is required}"
: "${BUILDROOT_PATCH_STAMP:?BUILDROOT_PATCH_STAMP is required}"
: "${BUILDROOT_PATCH_LOCK:?BUILDROOT_PATCH_LOCK is required}"
: "${SDK_INSTALL_DIR:?SDK_INSTALL_DIR is required}"
: "${SDK_INSTALL_STAMP:?SDK_INSTALL_STAMP is required}"
: "${CCACHE_DIR:?CCACHE_DIR is required}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required}"

[[ "${FORCE:-0}" == 0 || "${FORCE:-0}" == 1 ]] || {
  echo 'FORCE must be 0 or 1' >&2
  exit 1
}

mkdir -p "$(dirname "${BUILDROOT_PATCH_LOCK}")"
exec 9>"${BUILDROOT_PATCH_LOCK%.patch}.build"
flock 9

./scripts/buildroot-setup.sh "${BUILDROOT_PATCH_LOCK}" "${BUILDROOT_TARBALL}" \
  "${BUILDROOT_HASH}" "${BOARD_DIR}" "${BUILDROOT_SRC_DIR}" \
  "${BUILDROOT_PATCH_STAMP}" "${BUILDROOT_PATCH}"

state=(python3 "${PWD}/scripts/state.py")
state_dir="${BOARD_DIR}/stamp/orchestration"
mkdir -p "${state_dir}"

make_args=(
  -j"${BUILDROOT_JOBS}" -C "${BUILDROOT_SRC_DIR}"
  O="${BOARD_DIR}" BR2_EXTERNAL="${PWD}" BR2_CCACHE_DIR="${CCACHE_DIR}"
  BR2_DL_DIR="${BUILDROOT_DL_DIR}" SDK_INSTALL_DIR="${SDK_INSTALL_DIR}"
  TPMDD_VERSION="${TPMDD_VERSION}" SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}"
  BR2_CCACHE=y
)

configure_args=(
  key
  --path "configs/${BOARD}_defconfig"
  --path Config.in
  --path external.desc
  --path "${BUILDROOT_PATCH_STAMP}"
  --path "${SDK_INSTALL_STAMP}"
  --path scripts/buildroot-board.sh
  --value "source=${BUILDROOT_SRC_DIR}"
  --value "sdk=${SDK_INSTALL_DIR}"
  --value "board=${BOARD_DIR}"
  --value "epoch=${SOURCE_DATE_EPOCH}"
)
while IFS= read -r -d '' path; do
  configure_args+=(--path "${path}")
done < <(find package -name Config.in \( -type f -o -type l \) -print0 | sort -z)

if [[ "${command}" == savedefconfig ]]; then
  if [[ ! -f "${BOARD_DIR}/.config" ]]; then
    make "${make_args[@]}" "${BOARD}_defconfig"
  fi
  make "${make_args[@]}" BR2_DEFCONFIG="${PWD}/configs/${BOARD}_defconfig" savedefconfig
  configure_key=$("${state[@]}" "${configure_args[@]}")
  "${state[@]}" save "${state_dir}/configure.json" --key "${configure_key}" --path "${BOARD_DIR}/.config"
  exit 0
fi

configure_key=$("${state[@]}" "${configure_args[@]}")
if [[ "${command}" == configure ]] || ! "${state[@]}" check "${state_dir}/configure.json" \
    --key "${configure_key}" --path "${BOARD_DIR}/.config"; then
  echo "${BOARD}: applying configuration"
  rm -f "${state_dir}/build.json"
  make "${make_args[@]}" "${BOARD}_defconfig"
  "${state[@]}" save "${state_dir}/configure.json" --key "${configure_key}" --path "${BOARD_DIR}/.config"
fi

if [[ "${command}" == linux-update-defconfig ]]; then
  linux_defconfig="linux/${BOARD}_defconfig"
  linux_dir=
  for candidate in "${BOARD_DIR}/build"/linux-*; do
    [[ -d "${candidate}" ]] || continue
    case "$(basename "${candidate}")" in
      linux-firmware*|linux-tools*|linux-pam*) continue ;;
    esac
    linux_dir="${candidate}"
    break
  done
  if [[ -z "${linux_dir}" ]]; then
    make "${make_args[@]}" linux-patch
    for candidate in "${BOARD_DIR}/build"/linux-*; do
      [[ -d "${candidate}" ]] || continue
      case "$(basename "${candidate}")" in
        linux-firmware*|linux-tools*|linux-pam*) continue ;;
      esac
      linux_dir="${candidate}"
      break
    done
  fi
  test -n "${linux_dir}"
  if [[ ! -f "${linux_dir}/.stamp_kconfig_fixup_done" || ! -f "${linux_dir}/.stamp_dotconfig" || \
      "${linux_defconfig}" -nt "${linux_dir}/.stamp_dotconfig" ]]; then
    make "${make_args[@]}" "${linux_dir}/.stamp_kconfig_fixup_done"
  fi
  make "${make_args[@]}" linux-update-defconfig
  exit 0
fi

[[ "${command}" == build ]] || exit 0

export TARGET_DIR="${BOARD_DIR}/target" BR2_EXTERNAL_TPMDD_PATH="${PWD}"

input_args=(
  key
  --exclude __pycache__
  --exclude '*.pyc'
  --path Makefile
  --path Config.in
  --path external.mk
  --path external.desc
  --path configs
  --path sdk
  --path linux
  --path board
  --path scripts
  --path package
  --path patches
  --path overlay
  --path buildroot.patch
  --value "source=${BUILDROOT_SRC_DIR}"
  --value "sdk=${SDK_INSTALL_DIR}"
  --value "board=${BOARD_DIR}"
  --value "epoch=${SOURCE_DATE_EPOCH}"
)
has_override_env=false
while IFS= read -r name; do
  case "${name}" in
    *PASSWORD*|*TOKEN*|*SECRET*) continue ;;
    *_OVERRIDE_SRCDIR) has_override_env=true ;;
  esac
  input_args+=(--value "${name}=${!name}")
done < <(compgen -e | LC_ALL=C sort | grep -E '^(TPMDD_|BR2_|[A-Za-z0-9_]+_OVERRIDE_SRCDIR$)' || true)

input_key=$("${state[@]}" "${input_args[@]}")
configuration_key=$("${state[@]}" key --path "${BOARD_DIR}/.config")
. scripts/image-lib.sh

outputs=(
  --metadata-path "${BOARD_DIR}/images/${BOARD}.${TPMDD_MEDIA_EXT}"
  --metadata-path "${BOARD_DIR}/images/rootfs.squashfs"
  --metadata-path "${BOARD_DIR}/images/rootfs-live.squashfs"
  --metadata-path "${BOARD_DIR}/images/rootfs-oci-latest-${TPMDD_ARCH}-linux.oci-image.tar"
  --metadata-path "${BOARD_DIR}/images/image.tar"
  --path "${BOARD_DIR}/images/image.manifest"
  --path "${BOARD_DIR}/images/image-${TPMDD_VERSION}.tar"
  --path "${BOARD_DIR}/images/image-${TPMDD_VERSION}.manifest"
  --path "${BOARD_DIR}/images/ssh_config"
  --path "${BOARD_DIR}/images/live-ssh/id-rsa"
  --path "${BOARD_DIR}/images/live-ssh/id-rsa.pub"
)

if [[ "${FORCE:-0}" == 0 && "${has_override_env}" == false && ! -e "${BOARD_DIR}/local.mk" && \
    -f "${state_dir}/packages.json" && ! -e "${state_dir}/packages.pending.json" ]]; then
  build_tree=$("${state[@]}" build-tree "${BOARD_DIR}")
  build_key=$("${state[@]}" key \
    --value "inputs=${input_key}" \
    --value "packages=${build_tree}" \
    --path "${BOARD_DIR}/.config" \
    --path "${state_dir}/packages.json")
  if "${state[@]}" check "${state_dir}/build.json" --key "${build_key}" "${outputs[@]}"; then
    echo "${BOARD}: up to date"
    exit 0
  fi
fi

packages=(python3 "${PWD}/scripts/package-state.py")
"${packages[@]}" prepare --root "${PWD}" --board "${BOARD_DIR}" \
  --source "${BUILDROOT_SRC_DIR}" -- "${make_args[@]}"

if [[ "${FORCE:-0}" == 0 && -f "${state_dir}/packages.json" && ! -e "${state_dir}/packages.pending.json" ]]; then
  build_tree=$("${state[@]}" build-tree "${BOARD_DIR}")
  build_key=$("${state[@]}" key \
    --value "inputs=${input_key}" \
    --value "packages=${build_tree}" \
    --path "${BOARD_DIR}/.config" \
    --path "${state_dir}/packages.json")
  if "${state[@]}" check "${state_dir}/build.json" --key "${build_key}" "${outputs[@]}"; then
    rm -f "${state_dir}/packages.next.json"
    echo "${BOARD}: up to date"
    exit 0
  fi
fi

if [[ "${FORCE:-0}" == 1 ]]; then
  echo "${BOARD}: forced build"
else
  echo "${BOARD}: inputs, package state or outputs changed; running incremental build"
fi

rm -f "${state_dir}/build.json"
"${packages[@]}" assemble --board "${BOARD_DIR}"

linux_dir=$("${packages[@]}" build-dir --board "${BOARD_DIR}" linux)
linux_defconfig="linux/${BOARD}_defconfig"
linux_changed=false
linux_built=
kernel_key=$("${state[@]}" key --path "${linux_defconfig}")
if [[ -f "${state_dir}/linux.key" ]]; then
  IFS= read -r previous_kernel < "${state_dir}/linux.key"
  [[ "${kernel_key}" == "${previous_kernel}" ]] || linux_changed=true
elif [[ -n "${linux_dir}" && -f "${linux_dir}/.stamp_configured" && \
    "${linux_defconfig}" -nt "${linux_dir}/.stamp_configured" ]]; then
  linux_changed=true
fi
if [[ -n "${linux_dir}" ]]; then
  if [[ "${linux_changed}" == true || ! -d "${linux_dir}" || ! -f "${linux_dir}/.stamp_configured" || \
      ! -d "${BOARD_DIR}/per-package/linux" ]]; then
    linux_changed=true
    if [[ -d "${linux_dir}" || -d "${BOARD_DIR}/per-package/linux" ]]; then
      make "${make_args[@]}" linux-dirclean
    fi
  elif [[ ! -f "${linux_dir}/.stamp_built" ]]; then
    linux_changed=true
  else
    linux_built="${linux_dir}/.stamp_built"
  fi
fi

for package in linux-tools keygcbench; do
  package_dir=$("${packages[@]}" build-dir --board "${BOARD_DIR}" "${package}")
  [[ -n "${package_dir}" ]] || continue
  package_cache="${BOARD_DIR}/per-package/${package}"
  if [[ ( -d "${package_dir}" || -d "${package_cache}" ) && \
      ( "${linux_changed}" == true || ! -d "${package_cache}" || ! -f "${package_dir}/.stamp_configured" || \
        ( -n "${linux_built}" && "${linux_built}" -nt "${package_dir}/.stamp_configured" ) ) ]]; then
    make "${make_args[@]}" "${package}-dirclean"
  fi
done

make "${make_args[@]}"

current_input_key=$("${state[@]}" "${input_args[@]}")
current_configuration_key=$("${state[@]}" key --path "${BOARD_DIR}/.config")
if [[ "${input_key}" != "${current_input_key}" || "${configuration_key}" != "${current_configuration_key}" ]]; then
  echo "${BOARD}: inputs changed during the build; not recording an up-to-date result" >&2
  exit 1
fi

"${packages[@]}" commit --root "${PWD}" --board "${BOARD_DIR}" \
  --source "${BUILDROOT_SRC_DIR}" -- "${make_args[@]}"
build_tree=$("${state[@]}" build-tree "${BOARD_DIR}")
build_key=$("${state[@]}" key \
  --value "inputs=${input_key}" \
  --value "packages=${build_tree}" \
  --path "${BOARD_DIR}/.config" \
  --path "${state_dir}/packages.json")
"${state[@]}" save "${state_dir}/configure.json" --key "${configure_key}" --path "${BOARD_DIR}/.config"
printf '%s\n' "${kernel_key}" > "${state_dir}/linux.key.tmp"
mv "${state_dir}/linux.key.tmp" "${state_dir}/linux.key"
"${state[@]}" save "${state_dir}/build.json" --key "${build_key}" "${outputs[@]}"
