#!/usr/bin/env bash
#
# install-firedrake-arch.sh
# -----------------------------------------------------------------------------
# Instalador automatizado do Firedrake em Arch Linux.
#
# Este script segue o guia "Firedrake - Comprehensive Installation Guide"
# (firedrake-arch-instalation-guide-postmortem.md) e implementa os 14 passos
# do "happy path" documentado, além das validações serial e paralela.
#
# Ambiente final esperado:
#   - OS: Arch Linux x86_64
#   - Python: 3.14.x dentro de ~/firedrake/venv-firedrake
#   - MPI: MPICH 5.x
#   - PETSc: v3.25.0 em ~/firedrake/petsc, PETSC_ARCH=arch-firedrake-default
#   - petsc4py: 3.25.x
#   - Firedrake: 2026.4.x
#
# Uso:
#   ./install-firedrake-arch.sh [opções]
#
# Opções:
#   -h, --help              Mostra esta ajuda e sai.
#   -n, --dry-run           Apenas imprime os comandos; não executa.
#   -d, --work-dir DIR      Diretório de trabalho (padrão: ~/firedrake).
#   -j, --jobs N            Paralelismo do make (padrão: nproc).
#       --skip-petsc-build  Reaproveita PETSc já compilado em PETSC_DIR.
#       --skip-venv         Reaproveita venv-firedrake existente.
#       --no-validate       Pula as validações serial e paralela finais.
#   -v, --verbose           Saída mais detalhada.
#
# Requisitos:
#   - Arch Linux (verificado via /etc/os-release).
#   - Acesso a sudo para instalar pacotes com pacman.
#   - Conexão à internet para clonar PETSc e baixar firedrake-configure.
#
# Autor: (reescrita baseada no post-mortem)
# Licença: MIT
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuração global
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

# Versões-alvo fixadas pelo guia. Não altere sem revisar o .md.
readonly TARGET_PYTHON_MAJOR=3
readonly TARGET_PYTHON_MINOR=14
readonly CYTHON_SPEC="Cython>=3.0,<3.2" # Cython 3.3.0 quebra petsc4py
readonly FIREDRAKE_PIP_SPEC='firedrake[check]'
readonly FIREDRAKE_EXPECTED_VERSION_PREFIX="2026.4"
readonly PETSC_CONFIGURED_OS="unknown" # Arch não é reconhecido pelo configure

# Diretórios e nomes fixos.
readonly PETSC_ARCH_NAME="arch-firedrake-default"
readonly VENV_NAME="venv-firedrake"
readonly CONFIGURE_SCRIPT_NAME="firedrake-configure"
readonly CONFIGURE_URL="https://raw.githubusercontent.com/firedrakeproject/firedrake/release/scripts/firedrake-configure"
readonly PETSC_REPO_URL="https://gitlab.com/petsc/petsc.git"

# Estado mutável (preenchido em runtime).
WORK_DIR="${HOME}/firedrake"
JOBS="$(nproc 2>/dev/null || echo 4)"
DRY_RUN=0
VERBOSE=0
SKIP_PETSC_BUILD=0
SKIP_VENV=0
NO_VALIDATE=0

VENV_DIR=""
CONFIGURE_SCRIPT=""
PETSC_DIR=""
PETSC_VERSION=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

readonly LOG_FILE_DEFAULT="${HOME}/firedrake-install.log"
LOG_FILE=""

log() {
  local level="$1"
  shift
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local msg="[${timestamp}] [${level}] $*"

  # stderr para WARN/ERROR, stdout para o resto.
  if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
    echo "${msg}" >&2
  else
    echo "${msg}"
  fi

  if [[ -n "${LOG_FILE}" && -w "$(dirname "${LOG_FILE}")" ]]; then
    echo "${msg}" >>"${LOG_FILE}"
  fi
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "${VERBOSE}" -eq 1 ]] && log "DEBUG" "$@" || true; }

die() {
  log_error "$@"
  exit 1
}

# -----------------------------------------------------------------------------
# Execução de comandos (respeita DRY_RUN)
# -----------------------------------------------------------------------------

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_debug "exec: $*"
  "$@"
}

# Executa comando como string (para pipes). Ainda respeita DRY_RUN.
run_shell() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] (shell) $*"
    return 0
  fi
  log_debug "exec-shell: $*"
  bash -c "$*"
}

# -----------------------------------------------------------------------------
# Error handling centralizado
# -----------------------------------------------------------------------------

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  log_error "Falha na linha ${line_no} (exit=${exit_code})."
  log_error "Consulte o log em: ${LOG_FILE:-<desconhecido>}"
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help) usage ;;
    -n | --dry-run)
      DRY_RUN=1
      shift
      ;;
    -v | --verbose)
      VERBOSE=1
      shift
      ;;
    -d | --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    -j | --jobs)
      JOBS="$2"
      shift 2
      ;;
    --skip-petsc-build)
      SKIP_PETSC_BUILD=1
      shift
      ;;
    --skip-venv)
      SKIP_VENV=1
      shift
      ;;
    --no-validate)
      NO_VALIDATE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *) die "Argumento desconhecido: $1 (use --help)" ;;
    esac
  done

  VENV_DIR="${WORK_DIR}/${VENV_NAME}"
  CONFIGURE_SCRIPT="${WORK_DIR}/${CONFIGURE_SCRIPT_NAME}"
  PETSC_DIR="${WORK_DIR}/petsc"
  LOG_FILE="${LOG_FILE_DEFAULT}"
}

# -----------------------------------------------------------------------------
# Verificações de pré-requisitos
# -----------------------------------------------------------------------------

# Verifica múltiplos comandos de uma vez e reporta todos os que faltam.
require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Comandos obrigatórios ausentes: ${missing[*]}"
  fi
}

# Verifica OS via /etc/os-release. Usa default expansion para evitar quebra
# com set -u caso ID não esteja definido.
check_os() {
  log_info "Verificando sistema operacional..."
  [[ -f /etc/os-release ]] || die "/etc/os-release não encontrado."

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "arch" ]]; then
    die "Este instalador suporta apenas Arch Linux. Detectado: ${PRETTY_NAME:-desconhecido}"
  fi

  if [[ "$(uname -m)" != "x86_64" ]]; then
    log_warn "Arquitetura detectada: $(uname -m). O guia assume x86_64."
  fi

  log_info "OS: ${PRETTY_NAME:-Arch Linux}"
}

# Verifica se o Python 3.x do sistema atende ao mínimo exigido.
check_python() {
  log_info "Verificando Python do sistema..."
  require_commands python3

  local version
  version="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  log_info "Python do sistema: ${version}"

  if ! python3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= (${TARGET_PYTHON_MAJOR}, ${TARGET_PYTHON_MINOR}) else 1)"; then
    log_warn "Python ${TARGET_PYTHON_MAJOR}.${TARGET_PYTHON_MINOR}+ é recomendado (guia usa 3.14.x)."
  fi
}

# Verifica se sudo existe E funciona (não apenas o binário).
check_sudo() {
  require_commands sudo
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
      log_info "sudo exigirá senha durante a instalação de pacotes."
    fi
  fi
}

# Verifica conectividade com hosts necessários.
check_network() {
  log_info "Verificando conectividade..."
  require_commands curl git
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    curl --fail --silent --show-error --head --max-time 10 \
      "https://raw.githubusercontent.com" >/dev/null ||
      die "Sem acesso a raw.githubusercontent.com"
    git ls-remote --heads "${PETSC_REPO_URL}" >/dev/null 2>&1 ||
      die "Sem acesso a ${PETSC_REPO_URL}"
  fi
  log_info "Conectividade OK."
}

# -----------------------------------------------------------------------------
# Passo 0 — dependências de sistema
# -----------------------------------------------------------------------------

install_system_dependencies() {
  log_info "Instalando dependências de sistema via pacman..."

  # Lista baseada no guia: compiladores, MPI (MPICH), ferramentas de build,
  # headers e utilitários. Ajuste conforme sua necessidade.
  local packages=(
    base-devel
    git
    curl
    wget
    cmake
    ninja
    pkgconf
    mpich
    gcc
    gcc-fortran
    openblas
    lapack
    hdf5
    hdf5-openmpi
    metis
    parmetis
    scotch
    suitesparse
    python
    python-pip
    python-virtualenv
    python-setuptools
    python-wheel
    python-packaging
  )

  run sudo pacman -S --needed --noconfirm "${packages[@]}"
  log_info "Dependências de sistema instaladas."
}

# -----------------------------------------------------------------------------
# Passo 1 — workspace
# -----------------------------------------------------------------------------

prepare_workspace() {
  log_info "Preparando workspace em ${WORK_DIR}..."
  run mkdir -p "${WORK_DIR}"
  run mkdir -p "$(dirname "${LOG_FILE}")"
  : >"${LOG_FILE}" 2>/dev/null || true
  log_info "Workspace pronto. Log: ${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Passo 2 — obter firedrake-configure
# -----------------------------------------------------------------------------

download_firedrake_configure() {
  log_info "Baixando ${CONFIGURE_SCRIPT_NAME}..."
  run curl --fail --location --retry 3 --retry-delay 2 \
    --output "${CONFIGURE_SCRIPT}" "${CONFIGURE_URL}"
  run chmod +x "${CONFIGURE_SCRIPT}"
  log_info "${CONFIGURE_SCRIPT_NAME} instalado em ${CONFIGURE_SCRIPT}"
}

verify_firedrake_configure() {
  log_info "Verificando ${CONFIGURE_SCRIPT_NAME}..."
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "${CONFIGURE_SCRIPT}" --help >/dev/null ||
      die "${CONFIGURE_SCRIPT_NAME} não respondeu a --help"
  fi
  log_info "${CONFIGURE_SCRIPT_NAME} funcional."
}

# -----------------------------------------------------------------------------
# Passo 3 — determinar versão do PETSc
# -----------------------------------------------------------------------------

determine_petsc_version() {
  log_info "Determinando versão do PETSc exigida pelo Firedrake..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    PETSC_VERSION="v3.25.0"
    log_info "[dry-run] PETSc alvo: ${PETSC_VERSION}"
    return
  fi

  PETSC_VERSION="$("${CONFIGURE_SCRIPT}" --os "${PETSC_CONFIGURED_OS}" --show-petsc-version)"
  [[ -n "${PETSC_VERSION}" ]] || die "firedrake-configure não retornou versão do PETSc."
  log_info "PETSc alvo: ${PETSC_VERSION}"
}

# -----------------------------------------------------------------------------
# Passo 4 — clonar PETSc
# -----------------------------------------------------------------------------

clone_petsc() {
  log_info "Clonando PETSc ${PETSC_VERSION} em ${PETSC_DIR}..."

  if [[ -d "${PETSC_DIR}/.git" ]]; then
    # Valida que o repositório existente é realmente o PETSc.
    local remote_url
    remote_url="$(git -C "${PETSC_DIR}" remote get-url origin 2>/dev/null || echo "")"
    if [[ "${remote_url}" != *"petsc"* ]]; then
      log_warn "Diretório ${PETSC_DIR} existe mas não é o repositório PETSc (origin=${remote_url})."
      log_warn "Removendo e reclonando."
      run rm -rf "${PETSC_DIR}"
    else
      log_info "Repositório PETSc já presente. Fazendo fetch da tag ${PETSC_VERSION}..."
      run git -C "${PETSC_DIR}" fetch --tags origin
      run git -C "${PETSC_DIR}" checkout "${PETSC_VERSION}"
    fi
  fi

  if [[ ! -d "${PETSC_DIR}/.git" ]]; then
    run git clone --branch "${PETSC_VERSION}" --depth 1 \
      "${PETSC_REPO_URL}" "${PETSC_DIR}"
  fi

  # Validação explícita de identidade (o guia encontrou um caso de repo errado).
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    local tag
    tag="$(git -C "${PETSC_DIR}" describe --tags --exact-match 2>/dev/null || echo "")"
    if [[ "${tag}" != "${PETSC_VERSION}" ]]; then
      log_warn "Tag atual (${tag}) difere de ${PETSC_VERSION}. Verifique manualmente."
    fi
  fi

  log_info "PETSc pronto em ${PETSC_DIR}."
}

# -----------------------------------------------------------------------------
# Passo 5 — limpar variáveis de ambiente conflitantes
# -----------------------------------------------------------------------------

clear_petsc_env() {
  log_info "Limpando PETSC_DIR/PETSC_ARCH do ambiente atual..."
  unset PETSC_DIR PETSC_ARCH || true
}

# -----------------------------------------------------------------------------
# Passos 6–8 — configurar, compilar e validar PETSc
# -----------------------------------------------------------------------------

configure_petsc() {
  log_info "Configurando PETSc (PETSC_ARCH=${PETSC_ARCH_NAME})..."

  if [[ -f "${PETSC_DIR}/${PETSC_ARCH_NAME}/lib/petsc/conf/petscvariables" ]]; then
    log_info "PETSc já configurado em ${PETSC_ARCH_NAME}. Pulando configure."
    return
  fi

  run_shell "cd '${PETSC_DIR}' && \
    python3 '${CONFIGURE_SCRIPT}' \
      --os '${PETSC_CONFIGURED_OS}' \
      --show-petsc-configure-options \
    | xargs -L1 ./configure"

  log_info "PETSc configurado."
}

build_petsc() {
  if [[ "${SKIP_PETSC_BUILD}" -eq 1 ]]; then
    log_info "--skip-petsc-build ativo: pulando compilação do PETSc."
    return
  fi

  log_info "Compilando PETSc com ${JOBS} jobs..."
  run make -C "${PETSC_DIR}" \
    PETSC_DIR="${PETSC_DIR}" \
    PETSC_ARCH="${PETSC_ARCH_NAME}" \
    -j"${JOBS}" all
  log_info "PETSc compilado."
}

validate_petsc() {
  if [[ "${SKIP_PETSC_BUILD}" -eq 1 ]]; then
    log_info "--skip-petsc-build ativo: pulando validação do PETSc."
    return
  fi

  log_info "Executando suite de testes do PETSc..."
  run make -C "${PETSC_DIR}" \
    PETSC_DIR="${PETSC_DIR}" \
    PETSC_ARCH="${PETSC_ARCH_NAME}" \
    check
  log_info "Validação do PETSc concluída."
}

# -----------------------------------------------------------------------------
# Passo 9 — criar/ativar venv
# -----------------------------------------------------------------------------

setup_venv() {
  if [[ "${SKIP_VENV}" -eq 1 && -d "${VENV_DIR}" ]]; then
    log_info "--skip-venv ativo: reaproveitando ${VENV_DIR}."
  else
    log_info "Criando virtualenv em ${VENV_DIR}..."
    if [[ -d "${VENV_DIR}" ]]; then
      log_warn "Removendo venv existente para garantir estado limpo."
      run rm -rf "${VENV_DIR}"
    fi
    run python3 -m venv "${VENV_DIR}"
  fi

  # Ativação no shell atual (necessária para os passos seguintes).
  # shellcheck disable=SC1091
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    source "${VENV_DIR}/bin/activate"
    log_info "Python ativo: $(which python) — $(python --version 2>&1)"
  fi
}

# -----------------------------------------------------------------------------
# Passo 10 — exportar ambiente do Firedrake
# -----------------------------------------------------------------------------

export_firedrake_env() {
  log_info "Exportando ambiente do Firedrake..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] export \$(python firedrake-configure --os unknown --show-env)"
    return
  fi

  # Gera e exporta as variáveis (PETSC_DIR, PETSC_ARCH, etc.).
  local env_output
  env_output="$(python "${CONFIGURE_SCRIPT}" --os "${PETSC_CONFIGURED_OS}" --show-env)"
  [[ -n "${env_output}" ]] || die "firedrake-configure --show-env retornou vazio."

  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    # Cada linha tem a forma "VAR=valor" ou "export VAR=valor".
    line="${line#export }"
    local var="${line%%=*}"
    local val="${line#*=}"
    # Remove quotes simples/duplas envolventes.
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    export "${var}=${val}"
  done <<<"${env_output}"

  log_info "PETSC_DIR=${PETSC_DIR:-<unset>}"
  log_info "PETSC_ARCH=${PETSC_ARCH:-<unset>}"

  [[ "${PETSC_ARCH:-}" == "${PETSC_ARCH_NAME}" ]] ||
    die "PETSC_ARCH esperado (${PETSC_ARCH_NAME}) difere do obtido (${PETSC_ARCH:-<unset>})."
}

# -----------------------------------------------------------------------------
# Passo 11 — dependências Python de build
# -----------------------------------------------------------------------------

install_python_build_deps() {
  log_info "Atualizando pip/setuptools/wheel/hatchling..."
  run python -m pip install --upgrade pip setuptools wheel hatchling

  log_info "Instalando Cython fixado (${CYTHON_SPEC})..."
  # Cython 3.3.0 quebra petsc4py. A faixa <3.2 evita a regressão.
  run python -m pip install "${CYTHON_SPEC}"

  log_info "Instalando NumPy..."
  run python -m pip install numpy

  log_info "Instalando dependências auxiliares (pybind11, pkgconfig, libsupermesh)..."
  run python -m pip install pybind11 pkgconfig libsupermesh

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    log_info "Cython: $(cython --version 2>&1 | head -n1)"
    log_info "NumPy include: $(python -c 'import numpy; print(numpy.get_include())')"
  fi
}

# -----------------------------------------------------------------------------
# Passo 12 — compilar petsc4py
# -----------------------------------------------------------------------------

build_petsc4py() {
  log_info "Compilando petsc4py a partir de ${PETSC_DIR}/src/binding/petsc4py..."
  # --no-build-isolation é essencial: garante que o Cython do venv (3.1.x)
  # seja usado em vez do Cython isolado (3.3.x) que quebraria petsc4py.
  run python -m pip install \
    --no-build-isolation \
    --no-cache-dir \
    "${PETSC_DIR}/src/binding/petsc4py"
  log_info "petsc4py instalado."
}

# -----------------------------------------------------------------------------
# Passo 13 — validar petsc4py
# -----------------------------------------------------------------------------

validate_petsc4py() {
  log_info "Validando importação de petsc4py..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] validação de petsc4py"
    return
  fi

  local version
  version="$(python -c 'from petsc4py import PETSc; print(PETSc.Sys.getVersion())')" ||
    die "Falha ao importar petsc4py."

  local location
  location="$(python -c 'import petsc4py; print(petsc4py.__file__)')"

  log_info "petsc4py versão: ${version}"
  log_info "petsc4py em: ${location}"

  # Garante que petsc4py vem do venv, não de /opt ou /usr.
  if [[ "${location}" != "${VENV_DIR}"* ]]; then
    die "petsc4py está sendo importado fora do venv: ${location}"
  fi
}

# -----------------------------------------------------------------------------
# Passo 14 — instalar Firedrake
# -----------------------------------------------------------------------------

install_firedrake() {
  log_info "Instalando Firedrake (${FIREDRAKE_PIP_SPEC})..."
  # --no-build-isolation: usa o Cython 3.1.x do venv.
  # --no-binary h5py: força build local do h5py contra o HDF5 do sistema.
  run python -m pip install \
    --no-build-isolation \
    --no-binary h5py \
    "${FIREDRAKE_PIP_SPEC}"
  log_info "Firedrake instalado."
}

# -----------------------------------------------------------------------------
# Validação final — serial e paralela
# -----------------------------------------------------------------------------

validate_firedrake_version() {
  log_info "Verificando versão instalada do Firedrake..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then return; fi

  local installed
  installed="$(python -c 'import importlib.metadata; print(importlib.metadata.version("firedrake"))')"
  log_info "Firedrake instalado: ${installed}"

  if [[ "${installed}" != ${FIREDRAKE_EXPECTED_VERSION_PREFIX}* ]]; then
    log_warn "Versão instalada (${installed}) difere do esperado (${FIREDRAKE_EXPECTED_VERSION_PREFIX}.x)."
  fi
}

validate_serial() {
  log_info "Executando teste serial do Firedrake..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then return; fi

  OMP_NUM_THREADS=1 python - <<'PY' || die "Teste serial falhou."
from firedrake import *

mesh = UnitSquareMesh(4, 4)
V = FunctionSpace(mesh, "CG", 1)
x, y = SpatialCoordinate(mesh)
u = Function(V)
u.interpolate(x + y)

print("Firedrake test successful")
print("DOFs:", V.dim())
print("u range:", u.dat.data_ro.min(), "to", u.dat.data_ro.max())
PY
  log_info "Teste serial OK."
}

validate_parallel() {
  log_info "Executando teste paralelo do Firedrake (2 ranks MPI)..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then return; fi

  local tmp_script
  tmp_script="$(mktemp --suffix=.py)"
  cat >"${tmp_script}" <<'PY'
from firedrake import *
print(f"Starting rank {COMM_WORLD.rank}/{COMM_WORLD.size}", flush=True)
mesh = UnitSquareMesh(4, 4)
V = FunctionSpace(mesh, "CG", 1)
x, y = SpatialCoordinate(mesh)
u = Function(V)
u.interpolate(x + y)
print(f"Rank {COMM_WORLD.rank}/{COMM_WORLD.size}: DOFs = {V.dim()}", flush=True)
PY

  OMP_NUM_THREADS=1 mpiexec -n 2 python "${tmp_script}" ||
    {
      rm -f "${tmp_script}"
      die "Teste paralelo falhou."
    }

  rm -f "${tmp_script}"
  log_info "Teste paralelo OK."
}

# -----------------------------------------------------------------------------
# Resumo final
# -----------------------------------------------------------------------------

print_summary() {
  log_info "========================================"
  log_info " Instalação concluída"
  log_info "========================================"
  log_info "Workspace:     ${WORK_DIR}"
  log_info "Virtualenv:    ${VENV_DIR}"
  log_info "PETSc:         ${PETSC_DIR} (${PETSC_ARCH_NAME})"
  log_info "Log:           ${LOG_FILE}"
  log_info ""
  log_info "Para usar o Firedrake em uma nova sessão:"
  log_info "  source ${VENV_DIR}/bin/activate"
  log_info "  export \$(python ${CONFIGURE_SCRIPT} --os ${PETSC_CONFIGURED_OS} --show-env)"
  log_info "  export OMP_NUM_THREADS=1"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

main() {
  parse_args "$@"

  log_info "========================================"
  log_info " Firedrake Installer v${SCRIPT_VERSION}"
  log_info "========================================"
  log_info "Work dir:  ${WORK_DIR}"
  log_info "Jobs:      ${JOBS}"
  log_info "Dry-run:   ${DRY_RUN}"
  log_info "Log:       ${LOG_FILE}"

  check_os
  check_python
  check_sudo
  check_network
  require_commands python3 curl git make

  prepare_workspace
  install_system_dependencies

  download_firedrake_configure
  verify_firedrake_configure
  determine_petsc_version

  clear_petsc_env
  clone_petsc
  configure_petsc
  build_petsc
  validate_petsc

  setup_venv
  export_firedrake_env
  install_python_build_deps
  build_petsc4py
  validate_petsc4py

  install_firedrake
  validate_firedrake_version

  if [[ "${NO_VALIDATE}" -eq 0 ]]; then
    validate_serial
    validate_parallel
  else
    log_info "--no-validate ativo: pulando validações serial/paralela."
  fi

  print_summary
}

main "$@"
