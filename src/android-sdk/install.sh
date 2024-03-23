#!/usr/bin/env bash

export ANDROID_HOME="${ANDROID_HOME:-"/usr/local/android/sdk"}"
export PATH=$PATH:$ANDROID_HOME/cmdline-tools:$ANDROID_HOME/cmdline-tools/bin

USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
UPDATE_RC="${UPDATE_RC:-"true"}"

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Bring in ID, ID_LIKE, VERSION_ID, VERSION_CODENAME
. /etc/os-release
# Get an adjusted ID independent of distro variants
MAJOR_VERSION_ID=$(echo ${VERSION_ID} | cut -d . -f 1)
if [ "${ID}" = "debian" ] || [ "${ID_LIKE}" = "debian" ]; then
    ADJUSTED_ID="debian"
elif [[ "${ID}" = "rhel" || "${ID}" = "fedora" || "${ID}" = "mariner" || "${ID_LIKE}" = *"rhel"* || "${ID_LIKE}" = *"fedora"* || "${ID_LIKE}" = *"mariner"* ]]; then
    ADJUSTED_ID="rhel"
    if [[ "${ID}" = "rhel" ]] || [[ "${ID}" = *"alma"* ]] || [[ "${ID}" = *"rocky"* ]]; then
        VERSION_CODENAME="rhel${MAJOR_VERSION_ID}"
    else
        VERSION_CODENAME="${ID}${MAJOR_VERSION_ID}"
    fi
else
    echo "Linux distro ${ID} not supported."
    exit 1
fi

if type apt-get > /dev/null 2>&1; then
    PKG_MANAGER=apt-get
elif type microdnf > /dev/null 2>&1; then
    PKG_MANAGER=microdnf
elif type dnf > /dev/null 2>&1; then
    PKG_MANAGER=dnf
elif type yum > /dev/null 2>&1; then
    PKG_MANAGER=yum
else
    echo "(Error) Unable to find a supported package manager."
    exit 1
fi

pkg_install() {
    if [ ${PKG_MANAGER} = "apt-get" ]; then
        apt-get -y install --no-install-recommends "$@"
    elif [ ${PKG_MANAGER} = "microdnf" ]; then
        microdnf -y install --refresh --best --nodocs --noplugins --setopt=install_weak_deps=0 "$@"
    else
        $PKG_MANAGER -y install "$@"
    fi
}

# Clean up
clean_up() {
    local pkg
    case ${ADJUSTED_ID} in
        debian)
            rm -rf /var/lib/apt/lists/*
            ;;
        rhel)
            for pkg in epel-release epel-release-latest packages-microsoft-prod; do
                ${PKG_MANAGER} -y remove $pkg 2>/dev/null || /bin/true
            done
            rm -rf /var/cache/dnf/* /var/cache/yum/*
            rm -f /etc/yum.repos.d/docker-ce.repo
            ;;
    esac
}
clean_up

# Ensure that login shells get the correct path if the user updated the PATH using ENV.
rm -f /etc/profile.d/00-restore-env.sh
echo "export PATH=${PATH//$(sh -lc 'echo $PATH')/\$PATH}" > /etc/profile.d/00-restore-env.sh
chmod +x /etc/profile.d/00-restore-env.sh

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

save2rc() {
    local _bashrc
    local _zshrc
    if [ "${UPDATE_RC}" = "true" ]; then
        case $ADJUSTED_ID in
            debian)
                _bashrc=/etc/bash.bashrc
                _zshrc=/etc/zsh/zshrc
                ;;
            rhel)
                _bashrc=/etc/bashrc
                _zshrc=/etc/zshrc
            ;;
        esac
        echo "Updating ${_bashrc} and ${_zshrc}..."
        if [[ "$(cat ${_bashrc})" != *"$1"* ]]; then
            echo -e "$1" >> "${_bashrc}"
        fi
        if [ -f "${_zshrc}" ] && [[ "$(cat ${_zshrc})" != *"$1"* ]]; then
            echo -e "$1" >> "${_zshrc}"
        fi
    fi
}


pkg_manager_update() {
    case $ADJUSTED_ID in
        debian)
            if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
                echo "Running apt-get update..."
                ${PKG_MANAGER} update -y
            fi
            ;;
        rhel)
            if [ ${PKG_MANAGER} = "microdnf" ]; then
                if [ "$(ls /var/cache/yum/* 2>/dev/null | wc -l)" = 0 ]; then
                    echo "Running ${PKG_MANAGER} makecache ..."
                    ${PKG_MANAGER} makecache
                fi
            else
                if [ "$(ls /var/cache/${PKG_MANAGER}/* 2>/dev/null | wc -l)" = 0 ]; then
                    echo "Running ${PKG_MANAGER} check-update ..."
                    set +e
                        stderr_messages=$(${PKG_MANAGER} -q check-update 2>&1)
                        rc=$?
                        # centos 7 sometimes returns a status of 100 when it apears to work.
                        if [ $rc != 0 ] && [ $rc != 100 ]; then
                            echo "(Error) ${PKG_MANAGER} check-update produced the following error message(s):"
                            echo "${stderr_messages}"
                            exit 1
                        fi
                    set -e
                fi
            fi
            ;;
    esac
}

require_packages() {
    case ${ADJUSTED_ID} in
        debian)
            if ! dpkg -s "$@" > /dev/null 2>&1; then
                pkg_manager_update
                pkg_install "$@"
            fi
            ;;
        rhel)
            if ! rpm -q "$@" > /dev/null 2>&1; then
                pkg_manager_update
                pkg_install "$@"
            fi
            ;;
    esac
}

export DEBIAN_FRONTEND=noninteractive

# Install dependencies,
require_packages ca-certificates zip unzip sed findutils util-linux
# Make sure passwd (Debian) and shadow-utils RHEL family is installed
if [ ${ADJUSTED_ID} = "debian" ]; then
    require_packages passwd
elif [ ${ADJUSTED_ID} = "rhel" ]; then
    require_packages shadow-utils
fi
# minimal RHEL installs may not include curl, or includes curl-minimal instead.
# Install curl if the "curl" command is not present.
if ! type curl > /dev/null 2>&1; then
    require_packages curl
fi

# Install Android SDK if not installed
if [ ! -d "${ANDROID_HOME}" ]; then
    # Create android-sdk group, dir, and set sticky bit
    if ! cat /etc/group | grep -e "^android-sdk:" > /dev/null 2>&1; then
        groupadd -r android-sdk
    fi
    usermod -a -G android-sdk ${USERNAME}
    umask 0002
    # Install Android SDK
    mkdir -p $ANDROID_HOME
    curl -sSLO "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    unzip commandlinetools-linux-11076708_latest.zip -d ${ANDROID_HOME}
    unlink commandlinetools-linux-11076708_latest.zip
    chown -R "${USERNAME}:android-sdk" ${ANDROID_HOME}
    find ${ANDROID_HOME} -type d -print0 | xargs -d '\n' -0 chmod g+s
    # Add sourcing of Android SDK into bashrc/zshrc files (unless disabled)
    save2rc "export ANDROID_HOME=$ANDROID_HOME PATH=$PATH:$ANDROID_HOME/cmdline-tools:$ANDROID_HOME/cmdline-tools/bin"
fi

# Clean up
clean_up

echo "Done!"