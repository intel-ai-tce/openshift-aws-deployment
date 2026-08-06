#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_FILE="$HOME/.config/openshift-aws/config.env"
HOST_CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"

if [[ ! -f "$HOST_CONFIG_FILE" ]]; then
  echo "ERROR: configuration file not found: $HOST_CONFIG_FILE" >&2
  echo "Create it with:" >&2
  echo "  mkdir -p '$HOME/.config/openshift-aws'" >&2
  echo "  cp '$ROOT_DIR/config.env.example' '$DEFAULT_CONFIG_FILE'" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$HOST_CONFIG_FILE"
cd "$ROOT_DIR"

IMAGE="${OCP_TOOLBOX_IMAGE:-ocp-aws-toolbox:4.20}"
CHANNEL="${OCP_CHANNEL:-stable-4.20}"
AWS_PROFILE_VALUE="${AWS_PROFILE:-default}"
AWS_REGION_VALUE="${AWS_REGION:-}"
INSTALL_DIR_REL="${INSTALL_DIR:-cluster}"

if [[ "$INSTALL_DIR_REL" == /* ]]; then
  echo "ERROR: INSTALL_DIR must be relative to the repository for the container workflow." >&2
  exit 1
fi

DOCKER=()
SELECTED_KUBECONFIG_SOURCE=""
SELECTED_KUBECONFIG_CONTAINER=""
KUBECONFIG_MOUNTS=()

usage() {
  cat <<'EOF2'
Usage:
  ./container.sh build
  ./container.sh versions
  ./container.sh shell
  ./container.sh kubeconfig
  ./container.sh preflight
  ./container.sh render
  ./container.sh install
  ./container.sh resume
  ./container.sh deploy
  ./container.sh status
  ./container.sh oc <oc arguments>
  ./container.sh logs
  ./container.sh destroy-cluster
  ./container.sh exec <command> [arguments...]
EOF2
}

choose_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "ERROR: Docker is not running or is not accessible." >&2
    echo "Run ./setup-docker.sh, then retry." >&2
    exit 1
  fi
}

first_existing_kubeconfig() {
  local candidate
  local -a candidates=()

  [[ -n "${KUBECONFIG:-}" ]] || return 1
  IFS=':' read -r -a candidates <<<"$KUBECONFIG"
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_kubeconfig() {
  local project_kubeconfig="$ROOT_DIR/${INSTALL_DIR_REL%/}/auth/kubeconfig"
  local host_kubeconfig=""
  local host_parent host_base

  KUBECONFIG_MOUNTS=()

  if [[ -f "$project_kubeconfig" ]]; then
    SELECTED_KUBECONFIG_SOURCE="$project_kubeconfig"
    SELECTED_KUBECONFIG_CONTAINER="/work/${INSTALL_DIR_REL%/}/auth/kubeconfig"
    return 0
  fi

  if host_kubeconfig="$(first_existing_kubeconfig 2>/dev/null)"; then
    host_parent="$(cd "$(dirname "$host_kubeconfig")" && pwd)"
    host_base="$(basename "$host_kubeconfig")"
    KUBECONFIG_MOUNTS+=(--volume "$host_parent:/host-kubeconfig:ro")
    SELECTED_KUBECONFIG_SOURCE="$host_kubeconfig"
    SELECTED_KUBECONFIG_CONTAINER="/host-kubeconfig/$host_base"
    return 0
  fi

  if [[ -f "$HOME/.kube/config" ]]; then
    KUBECONFIG_MOUNTS+=(--volume "$HOME/.kube:/hosthome/.kube:ro")
    SELECTED_KUBECONFIG_SOURCE="$HOME/.kube/config"
    SELECTED_KUBECONFIG_CONTAINER="/hosthome/.kube/config"
    return 0
  fi

  SELECTED_KUBECONFIG_SOURCE="(not created yet) $project_kubeconfig"
  SELECTED_KUBECONFIG_CONTAINER="/work/${INSTALL_DIR_REL%/}/auth/kubeconfig"
}

require_existing_kubeconfig() {
  resolve_kubeconfig
  if [[ "$SELECTED_KUBECONFIG_SOURCE" == "(not created yet) "* ]]; then
    echo "ERROR: no kubeconfig is available." >&2
    echo "Checked this deployment, host \$KUBECONFIG, and ~/.kube/config." >&2
    exit 1
  fi
}

container_path_for_host_home_file() {
  local host_path="$1"
  if [[ "$host_path" == "$HOME/"* ]]; then
    printf '/hosthome/%s\n' "${host_path#"$HOME/"}"
    return 0
  fi
  return 1
}

run_container() {
  local tty_args=(-i)
  local mounts=(--volume "$ROOT_DIR:/work")
  local config_parent config_base container_config

  resolve_kubeconfig
  mounts+=("${KUBECONFIG_MOUNTS[@]}")

  config_parent="$(cd "$(dirname "$HOST_CONFIG_FILE")" && pwd)"
  config_base="$(basename "$HOST_CONFIG_FILE")"
  mounts+=(--volume "$config_parent:/host-config:ro")
  container_config="/host-config/$config_base"

  if [[ -d "$HOME/.aws" ]]; then
    mounts+=(--volume "$HOME/.aws:/hosthome/.aws:ro")
  fi
  if [[ -d "$HOME/.config/openshift-aws" ]]; then
    mounts+=(--volume "$HOME/.config/openshift-aws:/hosthome/.config/openshift-aws:ro")
  fi

  local input_file container_input_path
  for input_file in "${PULL_SECRET_FILE:-}" "${SSH_PUBLIC_KEY:-}"; do
    [[ -n "$input_file" && -f "$input_file" ]] || continue
    if container_input_path="$(container_path_for_host_home_file "$input_file")"; then
      mounts+=(--volume "$input_file:$container_input_path:ro")
    else
      echo "ERROR: container input file must be under HOME: $input_file" >&2
      echo "Use a path such as ~/.config/openshift-aws or ~/.ssh." >&2
      exit 1
    fi
  done

  if [[ -t 0 && -t 1 ]]; then
    tty_args+=(-t)
  fi

  local env_args=(
    --env HOME=/hosthome
    --env CONFIG_FILE="$container_config"
    --env AWS_PROFILE="$AWS_PROFILE_VALUE"
    --env AWS_REGION="$AWS_REGION_VALUE"
    --env AWS_DEFAULT_REGION="$AWS_REGION_VALUE"
    --env AWS_SDK_LOAD_CONFIG=1
    --env KUBECONFIG="$SELECTED_KUBECONFIG_CONTAINER"
  )

  local var
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN; do
    if [[ -n "${!var:-}" ]]; then
      env_args+=(--env "$var=${!var}")
    fi
  done

  "${DOCKER[@]}" run --rm \
    "${tty_args[@]}" \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    --workdir /work \
    "${env_args[@]}" \
    "${mounts[@]}" \
    "$IMAGE" \
    "$@"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  -h|--help|help|"") usage; exit 0 ;;
esac

choose_docker

case "$cmd" in
  build)
    "${DOCKER[@]}" build --build-arg "OCP_CHANNEL=$CHANNEL" --tag "$IMAGE" --file Dockerfile .
    ;;
  versions)
    run_container bash -c 'aws --version; openshift-install version; oc version --client; jq --version'
    ;;
  shell) run_container bash ;;
  kubeconfig)
    resolve_kubeconfig
    printf 'Host source: %s\n' "$SELECTED_KUBECONFIG_SOURCE"
    printf 'Container:   %s\n' "$SELECTED_KUBECONFIG_CONTAINER"
    ;;
  preflight) run_container ./preflight.sh ;;
  render) run_container ./render-install-config.sh ;;
  install|resume) run_container ./install-cluster.sh ;;
  deploy)
    if pgrep -f '[o]penshift-install create cluster' >/dev/null 2>&1; then
      echo "ERROR: an installer is already running on the bastion host." >&2
      exit 1
    fi
    run_container bash -c './preflight.sh && ./render-install-config.sh && ./install-cluster.sh'
    ;;
  status) run_container ./status.sh ;;
  oc)
    require_existing_kubeconfig
    run_container oc "$@"
    ;;
  logs)
    if [[ ! -f "$ROOT_DIR/${INSTALL_DIR_REL%/}/.openshift_install.log" ]]; then
      echo "ERROR: installer log not found: $ROOT_DIR/${INSTALL_DIR_REL%/}/.openshift_install.log" >&2
      exit 1
    fi
    tail -f "$ROOT_DIR/${INSTALL_DIR_REL%/}/.openshift_install.log"
    ;;
  destroy-cluster) run_container ./destroy-cluster.sh ;;
  exec)
    if [[ "$#" -eq 0 ]]; then
      echo "ERROR: exec requires a command." >&2
      exit 1
    fi
    run_container "$@"
    ;;
  *) echo "ERROR: unknown command: $cmd" >&2; usage; exit 1 ;;
esac
