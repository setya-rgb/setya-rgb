#!/usr/bin/env bash
# Android SDK + NDK Installer for Termux
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
readonly INSTALL_ROOT="$PREFIX/opt/android"
readonly SDK_ROOT="$INSTALL_ROOT/sdk"
readonly NDK_ROOT="$INSTALL_ROOT/ndk"
readonly TMP_DIR="$PREFIX/tmp/android-installer"
readonly JAVA_HOME_DIR="$PREFIX/lib/jvm/java-21-openjdk"

# SDK Command-line Tools
readonly CMDLINE_TOOLS_VERSION="11076708"
readonly CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"

# NDK - using release name (r26d) instead of build number
readonly NDK_RELEASE="r26d"
readonly NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_RELEASE}-linux.zip"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
warning() { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
fatal() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
    rm -rf "$TMP_DIR"
    info "Cleaned up temporary files"
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
require_termux() {
    command -v pkg >/dev/null 2>&1 || fatal "This installer must be run inside Termux."
}

require_java() {
    [[ -d "$JAVA_HOME_DIR" ]] || fatal "OpenJDK 21 not found. Run: pkg install openjdk-21"
    export JAVA_HOME="$JAVA_HOME_DIR"
    export PATH="$JAVA_HOME/bin:$PATH"
    java -version >/dev/null 2>&1 || fatal "Java is not working"
}

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    info "Installing dependencies..."
    pkg update -y || fatal "Failed to update packages"
    pkg install -y \
        openjdk-21 \
        gradle \
        unzip \
        wget \
        p7zip \
        findutils || fatal "Failed to install dependencies"
}

# -----------------------------------------------------------------------------
# Directories
# -----------------------------------------------------------------------------
prepare_workspace() {
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR" "$SDK_ROOT" "$INSTALL_ROOT"
    cd "$TMP_DIR"
}

# -----------------------------------------------------------------------------
# SDK
# -----------------------------------------------------------------------------
install_sdk() {
    info "Downloading Android SDK Command Line Tools..."
    wget --quiet --show-progress "$CMDLINE_TOOLS_URL" -O cmdline-tools.zip || fatal "SDK tools download failed"
    unzip -q cmdline-tools.zip -d sdk-extract || fatal "Failed to extract SDK tools"

    mkdir -p "$SDK_ROOT/cmdline-tools/latest"
    cp -r sdk-extract/cmdline-tools/* "$SDK_ROOT/cmdline-tools/latest/"

    export ANDROID_HOME="$SDK_ROOT"
    export ANDROID_SDK_ROOT="$SDK_ROOT"
    export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$PATH"

    local sdkmanager="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
    [[ -x "$sdkmanager" ]] || fatal "sdkmanager not found after extraction"

    mkdir -p "$HOME/.android"
    touch "$HOME/.android/repositories.cfg"

    info "Accepting Android licenses (non-interactive)..."
    yes | "$sdkmanager" --licenses >/dev/null 2>&1 || warning "License acceptance may have failed, but continuing"

    info "Installing SDK packages..."
    "$sdkmanager" \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" || fatal "Failed to install SDK packages"

    success "Android SDK installed"
}

# -----------------------------------------------------------------------------
# NDK
# -----------------------------------------------------------------------------
install_ndk() {
    info "Downloading Android NDK ${NDK_RELEASE}..."
    wget --quiet --show-progress "$NDK_URL" -O ndk.zip || fatal "NDK download failed"
    unzip -q ndk.zip -d ndk-extract || fatal "Failed to extract NDK"

    # Find the extracted NDK directory (e.g., android-ndk-r26d)
    local ndk_dir
    ndk_dir="$(find ndk-extract -maxdepth 1 -type d -name 'android-ndk*' | head -n1)"
    [[ -n "$ndk_dir" ]] || fatal "Unable to locate extracted NDK"

    rm -rf "$NDK_ROOT"
    mv "$ndk_dir" "$NDK_ROOT"

    success "Android NDK installed at $NDK_ROOT"
}

# -----------------------------------------------------------------------------
# Shell Configuration
# -----------------------------------------------------------------------------
append_bash_config() {
    local file="$1"
    [[ -f "$file" ]] || touch "$file"

    # Remove old block
    sed -i '/# Android SDK/,/# End Android SDK/d' "$file"

    cat >> "$file" <<EOF

# Android SDK
export JAVA_HOME="$JAVA_HOME_DIR"
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_NDK_HOME="$NDK_ROOT"
export ANDROID_NDK_ROOT="$NDK_ROOT"
export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_NDK_HOME:\$PATH"
# End Android SDK
EOF
}

append_fish_config() {
    local file="$1"
    mkdir -p "$(dirname "$file")"

    # Remove old block
    sed -i '/# Android SDK/,/# End Android SDK/d' "$file" 2>/dev/null || true

    cat >> "$file" <<EOF

# Android SDK
set -gx JAVA_HOME "$JAVA_HOME_DIR"
set -gx ANDROID_HOME "$SDK_ROOT"
set -gx ANDROID_SDK_ROOT "$SDK_ROOT"
set -gx ANDROID_NDK_HOME "$NDK_ROOT"
set -gx ANDROID_NDK_ROOT "$NDK_ROOT"
fish_add_path \$JAVA_HOME/bin
fish_add_path \$ANDROID_HOME/cmdline-tools/latest/bin
fish_add_path \$ANDROID_HOME/platform-tools
fish_add_path \$ANDROID_NDK_HOME
# End Android SDK
EOF
}

configure_shells() {
    info "Updating shell configuration..."
    append_bash_config "$PREFIX/etc/bash.bashrc"
    append_bash_config "$HOME/.zshrc" 2>/dev/null || true  # skip if zsh not used
    append_fish_config "$HOME/.config/fish/config.fish" 2>/dev/null || true
    success "Shell configuration updated"
}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
verify_installation() {
    info "Verifying installation..."

    command -v java >/dev/null && success "Java OK" || warning "Java not in PATH"
    command -v sdkmanager >/dev/null && success "sdkmanager OK" || warning "sdkmanager not in PATH"
    [[ -x "$SDK_ROOT/platform-tools/adb" ]] && success "ADB OK" || warning "ADB not found"
    [[ -x "$NDK_ROOT/ndk-build" ]] && success "NDK OK" || warning "ndk-build not found"

    echo
    echo "Installation paths:"
    echo "  Android SDK : $SDK_ROOT"
    echo "  Android NDK : $NDK_ROOT"
    echo "  Java Home   : $JAVA_HOME_DIR"
    echo
    success "Installation completed successfully!"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo
    echo "======================================="
    echo " Android SDK & NDK Installer (Termux) "
    echo "======================================="
    echo

    require_termux
    install_dependencies
    require_java
    prepare_workspace
    install_sdk
    install_ndk
    configure_shells
    verify_installation

    echo
    echo "Restart Termux or run:"
    echo "    source $PREFIX/etc/bash.bashrc"
    echo
}

main "$@"