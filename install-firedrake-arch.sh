#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="${HOME}/firedrake"

check_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    return 1
  fi
}

check_installer_prerequisites() {
  echo "Checking installer prerequisites..."

  check_command python3
  check_command curl
  check_command git
  check_command sudo

  echo "Installer rerequisites OK."
}

prepare_workspace() {
  echo "Preparing workspace..."

  mkdir -p "${WORK_DIR}"

  echo "Workspace: ${WORK_DIR}"
}

check_os() {
  echo "Checking operating system..."

  if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Cannot determine operating system." >&2
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID}" != "arch" ]]; then
    echo "ERROR: This installer currently supports Arch Linux only." >&2
    echo "Detected OS: ${PRETTY_NAME:-unknown}" >&2
    return 1
  fi

  echo "Operating system: ${PRETTY_NAME}"
}

install_system_dependencies() {
  echo "Installing system dependencies..."

  local packages=(
    ...
  )

  sudo pacman -S --needed "${packages[@]}"

  echo "System dependencies installed."
}

download_firedrake_configure() {
  echo "Obtaining firedrake-configure..."

  local configure_script="${WORK_DIR}/firedrake-configure"

  curl --fail --location --output "${configure_script}" \
    "https://raw.githubusercontent.com/firedrakeproject/firedrake/release/scripts/firedrake-configure"

  chmod +x "${configure_script}"

  echo "firedrake-configure installed at:"
  echo "  ${configure_script}"
}

verify_firedrake_configure() {
  echo "Verifying firedrake-configure..."

  "${WORK_DIR}/firedrake-configure" --help >/dev/null

  echo "firedrake-configure is functional."
}

determine_petsc_version() {
  echo "Determining required PETSc version..."

  local petsc_version

  petsc_version="$(
    "${WORK_DIR}/firedrake-configure" \
      --os unknown \
      --show-petsc-version
  )"

  echo "Required PETSc version: ${petsc_version}"
}

main() {
  echo "========================================"
  echo " Firedrake Installer"
  echo "========================================"

  check_os
  check_installer_prerequisites
  prepare_workspace

  install_system_dependencies

  download_firedrake_configure
  verify_firedrake_configure

  determine_petsc_version

  echo
  echo "Installation stage complete."
}

main "$@"
