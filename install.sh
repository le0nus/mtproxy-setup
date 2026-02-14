#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# MTProto Proxy (Telemt) Installer
# https://github.com/le0nus/mtproxy-setup
#
# Usage: curl -fsSL https://raw.githubusercontent.com/le0nus/mtproxy-setup/master/install.sh | sudo bash
# ============================================================================

INSTALL_DIR="/opt/telemt"
DOCKER_IMAGE="whn0thacked/telemt-docker:latest"

# --- Colors & helpers -------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ask() {
    local prompt="$1" default="$2" reply
    echo -en "${BOLD}${prompt}${NC} [${default}]: " >&2
    read -r reply </dev/tty
    echo "${reply:-$default}"
}

# --- Docker Compose wrapper -------------------------------------------------

# Detect whether to use "docker compose" (plugin) or "docker-compose" (standalone)
detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        # Install compose plugin (package name differs: docker-compose-v2 on Ubuntu, docker-compose-plugin on Docker repo)
        # Note: < /dev/null prevents apt from reading stdin (which is the curl pipe in curl|bash mode)
        info "Installing Docker Compose plugin..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq < /dev/null
            apt-get install -y -qq docker-compose-v2 < /dev/null 2>/dev/null \
                || apt-get install -y -qq docker-compose-plugin < /dev/null 2>/dev/null \
                || true
        elif command -v yum &>/dev/null; then
            yum install -y -q docker-compose-plugin < /dev/null 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q docker-compose-plugin < /dev/null 2>/dev/null || true
        fi
        # Recheck
        if docker compose version &>/dev/null; then
            COMPOSE_CMD="docker compose"
        else
            error "Docker Compose is not available. Install it manually: https://docs.docker.com/compose/install/"
        fi
    fi
    success "Compose: ${COMPOSE_CMD} ($(${COMPOSE_CMD} version --short 2>/dev/null || ${COMPOSE_CMD} version))"
}

# --- Uninstall --------------------------------------------------------------

uninstall() {
    info "Uninstalling MTProto Proxy..."

    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi

    # Detect compose command
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD=""
    fi

    if [[ -f "${INSTALL_DIR}/docker-compose.yml" && -n "$COMPOSE_CMD" ]]; then
        info "Stopping container..."
        cd "${INSTALL_DIR}"
        ${COMPOSE_CMD} down --remove-orphans 2>/dev/null || true
    fi

    if docker rm -f telemt &>/dev/null; then
        info "Removed telemt container"
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf "${INSTALL_DIR}"
        success "Removed ${INSTALL_DIR}"
    else
        info "Nothing to remove (${INSTALL_DIR} not found)"
    fi

    success "Uninstall complete"
    exit 0
}

# --- Pre-flight checks ------------------------------------------------------

preflight() {
    info "Checking environment..."

    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi

    if ! command -v openssl &>/dev/null; then
        error "openssl is required but not installed"
    fi

    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
        local proc
        proc=$(ss -tlnp | grep ':443 ' | head -1)
        warn "Port 443 is already in use:"
        echo "  $proc"
        echo ""
        local answer
        answer=$(ask "Stop the service occupying port 443 and continue? (y/n)" "y")
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            error "Port 443 must be free. Exiting."
        fi

        # Try to detect and stop common services
        if systemctl is-active --quiet nginx 2>/dev/null; then
            info "Stopping nginx..."
            systemctl stop nginx && systemctl disable nginx
        fi
        if systemctl is-active --quiet angie 2>/dev/null; then
            info "Stopping angie..."
            systemctl stop angie && systemctl disable angie
        fi
        if systemctl is-active --quiet apache2 2>/dev/null; then
            info "Stopping apache2..."
            systemctl stop apache2 && systemctl disable apache2
        fi
        if systemctl is-active --quiet httpd 2>/dev/null; then
            info "Stopping httpd..."
            systemctl stop httpd && systemctl disable httpd
        fi

        # Verify port is now free
        if ss -tlnp 2>/dev/null | grep -q ':443 '; then
            error "Port 443 is still in use. Please free it manually and re-run the script."
        fi
    fi

    success "Environment OK"
}

# --- Docker installation ----------------------------------------------------

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker is already installed: $(docker --version)"
    else
        info "Installing Docker..."

        if ! command -v curl &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq < /dev/null && apt-get install -y -qq curl < /dev/null
            elif command -v yum &>/dev/null; then
                yum install -y -q curl < /dev/null
            elif command -v dnf &>/dev/null; then
                dnf install -y -q curl < /dev/null
            else
                error "Cannot install curl. Please install it manually."
            fi
        fi

        curl -fsSL https://get.docker.com | sh -s -- < /dev/null

        systemctl enable docker
        systemctl start docker

        success "Docker installed: $(docker --version)"
    fi

    detect_compose
}

# --- Interactive configuration ----------------------------------------------

configure() {
    echo ""
    echo -e "${BOLD}=== MTProto Proxy Configuration ===${NC}"
    echo ""

    # Port
    PROXY_PORT=$(ask "Proxy port" "443")

    # TLS domain for masking
    echo ""
    info "TLS domain is used to disguise proxy traffic as regular HTTPS."
    info "Choose a popular website that is NOT blocked in the target region."
    echo ""
    TLS_DOMAIN=$(ask "TLS masking domain (fake SNI)" "api.vk.com")

    # Strip protocol and path if user pasted a URL (pure bash, no pipes)
    TLS_DOMAIN="${TLS_DOMAIN#http://}"
    TLS_DOMAIN="${TLS_DOMAIN#https://}"
    TLS_DOMAIN="${TLS_DOMAIN%%/*}"

    # Metrics
    echo ""
    local metrics_answer
    metrics_answer=$(ask "Enable metrics endpoint on port 9090? (y/n)" "n")
    if [[ "$metrics_answer" == "y" || "$metrics_answer" == "Y" ]]; then
        METRICS_ENABLED=true
    else
        METRICS_ENABLED=false
    fi

    # Secret generation
    SECRET=$(openssl rand -hex 16)

    # Build the ee-prefixed secret with hex-encoded domain
    DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')
    FULL_SECRET="ee${SECRET}${DOMAIN_HEX}"

    echo ""
    echo -e "${BOLD}=== Configuration Summary ===${NC}"
    echo "  Port:        ${PROXY_PORT}"
    echo "  TLS domain:  ${TLS_DOMAIN}"
    echo "  Metrics:     ${METRICS_ENABLED}"
    echo "  Secret (ee): ${FULL_SECRET}"
    echo "  Install dir: ${INSTALL_DIR}"
    echo ""

    local confirm
    confirm=$(ask "Proceed with installation? (y/n)" "y")
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        error "Installation cancelled."
    fi
}

# --- File generation --------------------------------------------------------

generate_files() {
    info "Creating ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"

    # telemt.toml
    info "Writing telemt.toml..."

    local metrics_block=""
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        metrics_block="
metrics_port = 9090
metrics_whitelist = [\"127.0.0.1\", \"::1\"]"
    fi

    cat > "${INSTALL_DIR}/telemt.toml" <<TOML
# Telemt MTProto Proxy configuration
# Generated by mtproxy-setup installer

show_link = ["proxy"]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PROXY_PORT}
listen_addr_ipv4 = "0.0.0.0"${metrics_block}

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_port = 443
fake_cert_len = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
proxy = "${SECRET}"

[[upstreams]]
type = "direct"
enabled = true
weight = 10
TOML

    # docker-compose.yml
    info "Writing docker-compose.yml..."

    local ports_block="      - \"${PROXY_PORT}:${PROXY_PORT}/tcp\""
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        ports_block="${ports_block}
      - \"127.0.0.1:9090:9090/tcp\""
    fi

    cat > "${INSTALL_DIR}/docker-compose.yml" <<YAML
services:
  telemt:
    image: ${DOCKER_IMAGE}
    container_name: telemt
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
${ports_block}
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
YAML

    success "Configuration files created"
}

# --- Launch -----------------------------------------------------------------

launch() {
    info "Pulling Docker image..."
    docker pull "${DOCKER_IMAGE}"

    info "Starting container..."
    cd "${INSTALL_DIR}"
    ${COMPOSE_CMD} up -d

    info "Waiting for container to start..."
    sleep 3

    if ${COMPOSE_CMD} ps --format '{{.State}}' 2>/dev/null | grep -qi "running"; then
        success "Container is running"
    elif ${COMPOSE_CMD} ps 2>/dev/null | grep -qi "up\|running"; then
        success "Container is running"
    else
        warn "Container may not have started. Checking logs..."
        ${COMPOSE_CMD} logs --tail=20
        sleep 2
        if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
            success "Container is running (port ${PROXY_PORT} is listening)"
        else
            error "Container failed to start. Check the logs above."
        fi
    fi
}

# --- Health check -----------------------------------------------------------

healthcheck() {
    info "Running health checks..."

    # Check port
    if ss -tlnp | grep -q ":${PROXY_PORT} "; then
        success "Port ${PROXY_PORT} is listening"
    else
        warn "Port ${PROXY_PORT} does not appear to be listening"
    fi

    # Check metrics if enabled
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        if curl -sf http://127.0.0.1:9090/metrics &>/dev/null; then
            success "Metrics endpoint is responding"
        else
            warn "Metrics endpoint is not responding (may take a moment)"
        fi
    fi

    # Show container logs
    echo ""
    info "Container logs:"
    ${COMPOSE_CMD} -f "${INSTALL_DIR}/docker-compose.yml" logs --tail=10
}

# --- Output connection link -------------------------------------------------

print_link() {
    # Detect public IP
    local public_ip
    public_ip=$(curl -sf https://ifconfig.me || curl -sf https://api.ipify.org || echo "YOUR_SERVER_IP")

    echo ""
    echo -e "${BOLD}=============================================${NC}"
    echo -e "${GREEN}  MTProto Proxy installed successfully!${NC}"
    echo -e "${BOLD}=============================================${NC}"
    echo ""
    echo -e "${BOLD}Connection link:${NC}"
    echo ""
    echo -e "  ${CYAN}tg://proxy?server=${public_ip}&port=${PROXY_PORT}&secret=${FULL_SECRET}${NC}"
    echo ""
    echo -e "${BOLD}HTTPS link (for sharing):${NC}"
    echo ""
    echo -e "  ${CYAN}https://t.me/proxy?server=${public_ip}&port=${PROXY_PORT}&secret=${FULL_SECRET}${NC}"
    echo ""
    echo -e "${BOLD}Details:${NC}"
    echo "  Server IP:   ${public_ip}"
    echo "  Port:        ${PROXY_PORT}"
    echo "  Secret (ee): ${FULL_SECRET}"
    echo "  TLS domain:  ${TLS_DOMAIN}"
    echo "  Config dir:  ${INSTALL_DIR}"
    echo ""
    echo -e "${BOLD}Management commands:${NC}"
    echo "  ${COMPOSE_CMD} -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo "  ${COMPOSE_CMD} -f ${INSTALL_DIR}/docker-compose.yml restart"
    echo "  ${COMPOSE_CMD} -f ${INSTALL_DIR}/docker-compose.yml down"
    echo ""
}

# --- Main -------------------------------------------------------------------

main() {
    # Handle --uninstall flag
    if [[ "${1:-}" == "--uninstall" || "${1:-}" == "uninstall" ]]; then
        uninstall
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   MTProto Proxy (Telemt) Installer       ║${NC}"
    echo -e "${BOLD}║   github.com/le0nus/mtproxy-setup        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    install_docker
    configure
    generate_files
    launch
    healthcheck
    print_link
}

main "$@"
