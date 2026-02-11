#!/bin/bash

# =============================================================================
# Quotio Build Configuration & Utilities
# =============================================================================
# Provides shared configuration and beautiful CLI output utilities
# =============================================================================

# Project settings
export PROJECT_NAME="Quotio"
export SCHEME="Quotio"
export BUNDLE_ID="dev.quotio.desktop"

# Paths
export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUILD_DIR="${PROJECT_DIR}/build"
export ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
export APP_PATH="${BUILD_DIR}/${PROJECT_NAME}.app"
export DMG_PATH="${BUILD_DIR}/${PROJECT_NAME}.dmg"
export RELEASE_DIR="${BUILD_DIR}/release"

# Code signing (set via environment or keychain)
export DEVELOPER_ID="${DEVELOPER_ID:-}"
export NOTARIZATION_KEYCHAIN_PROFILE="${NOTARIZATION_KEYCHAIN_PROFILE:-quotio-notarization}"

# GitHub
export GITHUB_REPO="nguyenphutrong/quotio"

# Sparkle
export SPARKLE_PRIVATE_KEY_PATH="${PROJECT_DIR}/.sparkle_private_key"
export APPCAST_PATH="${RELEASE_DIR}/appcast.xml"

# =============================================================================
# Terminal Detection & Colors
# =============================================================================

# Detect if terminal supports colors and unicode
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    SUPPORTS_COLOR=true
    # Check for unicode support
    if [[ "${LANG:-}" == *"UTF-8"* ]] || [[ "${LC_ALL:-}" == *"UTF-8"* ]] || [[ "${LC_CTYPE:-}" == *"UTF-8"* ]]; then
        SUPPORTS_UNICODE=true
    else
        SUPPORTS_UNICODE=false
    fi
else
    SUPPORTS_COLOR=false
    SUPPORTS_UNICODE=false
fi

# Colors
if [[ "$SUPPORTS_COLOR" == true ]]; then
    export RED='\033[0;31m'
    export GREEN='\033[0;32m'
    export YELLOW='\033[1;33m'
    export BLUE='\033[0;34m'
    export MAGENTA='\033[0;35m'
    export CYAN='\033[0;36m'
    export WHITE='\033[1;37m'
    export GRAY='\033[0;90m'
    export BOLD='\033[1m'
    export DIM='\033[2m'
    export NC='\033[0m' # No Color
else
    export RED=''
    export GREEN=''
    export YELLOW=''
    export BLUE=''
    export MAGENTA=''
    export CYAN=''
    export WHITE=''
    export GRAY=''
    export BOLD=''
    export DIM=''
    export NC=''
fi

# Symbols (with fallbacks)
if [[ "$SUPPORTS_UNICODE" == true ]]; then
    export SYM_CHECK="✓"
    export SYM_CROSS="✗"
    export SYM_ARROW="→"
    export SYM_BULLET="•"
    export SYM_WARN="⚠"
    export SYM_INFO="ℹ"
    export SYM_GEAR="⚙"
    export SYM_PACKAGE="📦"
    export SYM_ROCKET="🚀"
    export SYM_CLOCK="⏱"
    export SYM_SPARKLE="✨"
    export SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
else
    export SYM_CHECK="[OK]"
    export SYM_CROSS="[X]"
    export SYM_ARROW="->"
    export SYM_BULLET="*"
    export SYM_WARN="[!]"
    export SYM_INFO="[i]"
    export SYM_GEAR="[*]"
    export SYM_PACKAGE="[P]"
    export SYM_ROCKET="[>]"
    export SYM_CLOCK="[T]"
    export SYM_SPARKLE="[*]"
    export SPINNER_CHARS="|/-\\"
fi

# =============================================================================
# Timing Utilities (bash 3.2 compatible)
# =============================================================================

SCRIPT_START_TIME=""
STEP_TIMERS_FILE="${TMPDIR:-/tmp}/.quotio_timers_$$"

start_timer() {
    SCRIPT_START_TIME=$(date +%s)
    rm -f "$STEP_TIMERS_FILE" 2>/dev/null
}

start_step_timer() {
    local step_name="${1:-default}"
    local now=$(date +%s)
    echo "${step_name}=${now}" >> "$STEP_TIMERS_FILE"
}

format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        echo "${hours}h ${mins}m"
    fi
}

get_step_duration() {
    local step_name="${1:-default}"
    local start_time=""
    if [ -f "$STEP_TIMERS_FILE" ]; then
        start_time=$(grep "^${step_name}=" "$STEP_TIMERS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    fi
    if [ -n "$start_time" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        format_duration $duration
    else
        echo "0s"
    fi
}

get_total_duration() {
    if [ -n "$SCRIPT_START_TIME" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - SCRIPT_START_TIME))
        format_duration $duration
    else
        echo "0s"
    fi
}

# =============================================================================
# File Size Utilities
# =============================================================================

format_file_size() {
    local size="${1:-0}"
    # Validate input is numeric
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return
    fi
    if [ "$size" -lt 1024 ]; then
        echo "${size} B"
    elif [ "$size" -lt 1048576 ]; then
        echo "$((size / 1024)) KB"
    elif [ "$size" -lt 1073741824 ]; then
        local mb=$((size * 10 / 1048576))
        echo "$((mb / 10)).$((mb % 10)) MB"
    else
        local gb=$((size * 100 / 1073741824))
        echo "$((gb / 100)).$((gb % 100)) GB"
    fi
}

get_file_size() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size=$(stat -f%z "$file" 2>/dev/null || stat --printf="%s" "$file" 2>/dev/null)
        format_file_size "$size"
    else
        echo "N/A"
    fi
}

# =============================================================================
# Logging Functions
# =============================================================================

# Basic logging with timestamps (optional)
log_info() { 
    echo -e "${GREEN}${SYM_CHECK}${NC} $1"
}

log_warn() { 
    echo -e "${YELLOW}${SYM_WARN}${NC} $1"
}

log_error() { 
    echo -e "${RED}${SYM_CROSS}${NC} $1"
}

log_step() { 
    echo -e "${BLUE}${SYM_ARROW}${NC} $1"
}

log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${GRAY}  $1${NC}"
    fi
}

# Indented sub-item logging
log_item() {
    echo -e "  ${GRAY}${SYM_BULLET}${NC} $1"
}

log_success() {
    echo -e "${GREEN}${SYM_CHECK}${NC} ${GREEN}$1${NC}"
}

log_failure() {
    echo -e "${RED}${SYM_CROSS}${NC} ${RED}$1${NC}"
}

# =============================================================================
# Box/Header Drawing
# =============================================================================

# Print a header box
print_header() {
    local title="$1"
    local width=${2:-60}
    local padding=$(( (width - ${#title} - 2) / 2 ))
    local i
    local border=""
    
    for ((i=0; i<width; i++)); do
        border="${border}═"
    done
    
    echo ""
    echo -e "${CYAN}╔${border}╗${NC}"
    printf "${CYAN}║${NC}%*s${BOLD}${WHITE}%s${NC}%*s${CYAN}║${NC}\n" $padding "" "$title" $((width - padding - ${#title})) ""
    echo -e "${CYAN}╚${border}╝${NC}"
    echo ""
}

# Print a section divider
print_divider() {
    local char="${1:-─}"
    local width=${2:-60}
    local i
    local line=""
    for ((i=0; i<width; i++)); do
        line="${line}${char}"
    done
    echo -e "${GRAY}${line}${NC}"
}

# Print a step header with number
print_step() {
    local step_num="$1"
    local total_steps="$2"
    local title="$3"
    
    echo ""
    echo -e "${BOLD}${BLUE}[${step_num}/${total_steps}]${NC} ${BOLD}${title}${NC}"
    print_divider "─" 50
}

# =============================================================================
# Progress Indicators
# =============================================================================

# Spinner for background processes
# Usage: start_spinner "Loading..."; long_command; stop_spinner
SPINNER_PID=""

start_spinner() {
    local message="${1:-Processing...}"
    local i=0
    local chars="$SPINNER_CHARS"
    local len=${#chars}
    
    (
        while true; do
            printf "\r${CYAN}%s${NC} %s" "${chars:i++%len:1}" "$message"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown
}

stop_spinner() {
    local status="${1:-0}"
    local message="${2:-}"
    
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    
    # Clear the spinner line
    printf "\r\033[K"
    
    # Print final status if message provided
    if [[ -n "$message" ]]; then
        if [[ "$status" == "0" ]]; then
            log_success "$message"
        else
            log_failure "$message"
        fi
    fi
}

# Simple progress bar
# Usage: print_progress 50 100 "Downloading"
print_progress() {
    local current=$1
    local total=$2
    local label="${3:-Progress}"
    local width=40
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r${label}: ${CYAN}[${NC}"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "${CYAN}]${NC} %3d%%" $percent
}

# =============================================================================
# Summary Tables
# =============================================================================

# Print a key-value pair
print_kv() {
    local key="$1"
    local value="$2"
    local key_width=${3:-20}
    printf "  ${GRAY}%-${key_width}s${NC} %s\n" "$key:" "$value"
}

# Print a summary box
print_summary() {
    local title="$1"
    shift
    
    echo ""
    echo -e "${BOLD}${title}${NC}"
    print_divider "─" 50
    
    while [[ $# -gt 0 ]]; do
        local key="$1"
        local value="$2"
        print_kv "$key" "$value"
        shift 2
    done
    echo ""
}

# =============================================================================
# Command Execution with Pretty Output
# =============================================================================

# Run a command with optional spinner and captured output
# Usage: run_cmd "Building project" xcodebuild ...
run_cmd() {
    local description="$1"
    shift
    local log_file="${BUILD_DIR}/cmd_$(date +%s).log"
    
    mkdir -p "${BUILD_DIR}"
    
    start_spinner "$description"
    
    if "$@" > "$log_file" 2>&1; then
        stop_spinner 0 "$description"
        rm -f "$log_file"
        return 0
    else
        local exit_code=$?
        stop_spinner 1 "$description"
        echo ""
        log_error "Command failed. Last 20 lines of output:"
        echo -e "${GRAY}"
        tail -20 "$log_file" 2>/dev/null || true
        echo -e "${NC}"
        return $exit_code
    fi
}

# Run xcodebuild with pretty output (filters verbose output)
run_xcodebuild() {
    local log_file="${BUILD_DIR}/xcodebuild.log"
    mkdir -p "${BUILD_DIR}"
    
    # Run xcodebuild and filter output
    if "$@" 2>&1 | tee "$log_file" | grep -E "^(Build|Archive|Compile|Link|Sign|Process|Copy|Touch|error:|warning:|\*\*)" | while read -r line; do
        if [[ "$line" == *"error:"* ]]; then
            echo -e "${RED}  ${SYM_CROSS} ${line}${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "${YELLOW}  ${SYM_WARN} ${line}${NC}"
        elif [[ "$line" == "** BUILD"* ]] || [[ "$line" == "** ARCHIVE"* ]]; then
            if [[ "$line" == *"SUCCEEDED"* ]]; then
                echo -e "${GREEN}  ${SYM_CHECK} ${line}${NC}"
            else
                echo -e "${RED}  ${SYM_CROSS} ${line}${NC}"
            fi
        else
            echo -e "${GRAY}  ${SYM_BULLET} ${line}${NC}"
        fi
    done; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed."
        exit 1
    fi
}

get_version() {
    local pbxproj="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"
    grep -m1 "MARKETING_VERSION" "$pbxproj" | sed 's/.*= \(.*\);/\1/'
}

get_build_number() {
    local pbxproj="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"
    grep -m1 "CURRENT_PROJECT_VERSION" "$pbxproj" | sed 's/.*= \(.*\);/\1/'
}

# Clean exit handler
cleanup_on_exit() {
    stop_spinner 2>/dev/null || true
    rm -f "$STEP_TIMERS_FILE" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# Initialize timer when config is sourced
start_timer
