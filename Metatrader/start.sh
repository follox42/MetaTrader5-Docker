#!/bin/bash

# Configuration variables
mt5file='/config/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe'
WINEPREFIX='/config/.wine'
WINEDEBUG='-all'
wine_executable="wine"
metatrader_version="5.0.36"
mt5server_port="8001"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

show_message() {
    echo $1
}

check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 is not installed. Please install it to continue."
        exit 1
    fi
}

is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

is_wine_python_package_installed() {
    $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

check_dependency "curl"
check_dependency "$wine_executable"

# Pre-init Wine prefix on first boot
if [ ! -d "/config/.wine/drive_c" ]; then
    show_message "[0/7] Pre-init Wine prefix"
    $wine_executable wineboot --init || true
    sleep 5
fi

# ALWAYS install Mono on every boot — idempotent
show_message "[1/7] Downloading and installing Mono (always — idempotent)..."
curl -L -o /tmp/mono.msi $mono_url
WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /tmp/mono.msi /qn
rm -f /tmp/mono.msi
show_message "[1/7] Mono installed."

if [ -e "$mt5file" ]; then
    show_message "[2/7] File $mt5file already exists."
else
    show_message "[2/7] File $mt5file is not installed. Installing..."
    $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    show_message "[3/7] Downloading MT5 installer..."
    curl -L -o /tmp/mt5setup.exe $mt5setup_url
    show_message "[3/7] Installing MetaTrader 5 (max 10min wait)..."
    $wine_executable "/tmp/mt5setup.exe" "/auto" &
    MT5_PID=$!

    for i in $(seq 1 60); do
        if [ -e "$mt5file" ]; then
            show_message "[3/7] terminal64.exe appeared after ${i}*10s"
            sleep 30
            break
        fi
        if ! ps -p $MT5_PID > /dev/null 2>&1; then
            show_message "[3/7] wine MT5 setup process exited after ${i}*10s"
            break
        fi
        if [ $((i % 6)) -eq 0 ]; then
            elapsed=$((i * 10))
            show_message "[3/7] still installing ${elapsed}s..."
        fi
        sleep 10
    done
    kill -9 $MT5_PID 2>/dev/null || true
    rm -f /tmp/mt5setup.exe

    if [ ! -e "$mt5file" ]; then
        show_message "[3/7] WARNING: terminal64.exe still missing after 10min — continuing anyway"
    fi
fi

if [ -e "$mt5file" ]; then
    show_message "[4/7] File $mt5file is installed. Running MT5..."
    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    show_message "[4/7] File $mt5file is not installed. MT5 cannot be run."
fi

if ! $wine_executable python --version 2>/dev/null; then
    show_message "[5/7] Installing Python in Wine..."
    curl -L $python_url -o /tmp/python-installer.exe
    $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
    rm /tmp/python-installer.exe
    show_message "[5/7] Python installed in Wine."
else
    show_message "[5/7] Python is already installed in Wine."
fi

show_message "[6/7] Installing Python libraries"
$wine_executable python -m pip install --upgrade --no-cache-dir pip
show_message "[6/7] Installing MetaTrader5 library in Windows"
if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    $wine_executable python -m pip install --no-cache-dir MetaTrader5==$metatrader_version
fi
# Wine side: mt5linux 0.1.9 + rpyc 5.0.1 (must match Linux side for binary protocol compat)
show_message "[6/7] Installing mt5linux==0.1.9 + rpyc==5.0.1 (force) in Windows"
$wine_executable python -m pip install --no-cache-dir --force-reinstall "mt5linux==0.1.9" "rpyc==5.0.1"

if ! is_wine_python_package_installed "python-dateutil"; then
    show_message "[6/7] Installing python-dateutil library in Windows"
    $wine_executable python -m pip install --no-cache-dir python-dateutil
fi

# Linux side: same versions as Wine — rpyc protocol must match between client and server.
# CRITICAL: gmag11 upstream had `pip install rpyc plumbum numpy` (no pin) → latest 6.x.
# Wine python had pinned rpyc 5.0.1 → mismatch → "ValueError: invalid message type: 18".
show_message "[6/7] Installing mt5linux==0.1.9 + rpyc==5.0.1 + plumbum==1.7.0 (force) in Linux"
pip install --break-system-packages --no-cache-dir --no-deps --force-reinstall \
    "mt5linux==0.1.9" \
    "rpyc==5.0.1" \
    "plumbum==1.7.0"
pip install --break-system-packages --no-cache-dir numpy

show_message "[6/7] Checking and installing pyxdg library in Linux if necessary"
if ! is_python_package_installed "pyxdg"; then
    pip install --break-system-packages --no-cache-dir pyxdg
fi

show_message "[7/7] Starting the mt5linux server..."
python3 -m mt5linux --host 0.0.0.0 -p $mt5server_port -w $wine_executable python.exe &
MT5LINUX_PID=$!

sleep 5

if ss -tuln | grep ":$mt5server_port" > /dev/null; then
    show_message "[7/7] The mt5linux server is running on port $mt5server_port."
else
    show_message "[7/7] Failed to start the mt5linux server on port $mt5server_port."
fi

# Keep script alive — linuxserver supervisord will restart it if it exits.
# Block on mt5linux server PID. If mt5linux dies, script exits and gets restarted.
show_message "[KEEPALIVE] script will block on mt5linux server PID $MT5LINUX_PID"
wait $MT5LINUX_PID
show_message "[KEEPALIVE] mt5linux server exited — start.sh ending (supervisord will restart)"
