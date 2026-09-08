#!/bin/sh
# Exit immediately if any command fails
set -e

# Update "VM_SRC"
VM_SRC="/path/to/your/opensmalltalk-vm"
BUILD_DIR="$VM_SRC/building/linux64x64/squeak.cog.spur/build"
TEMPLATE_DIR="$VM_SRC/building/linux64x64/squeak.cog.spur"

FREEBSD_TRIPLET=$(cc -dumpmachine)

echo "==> Pulling latest OpenSmalltalk VM source code..."
cd "$VM_SRC"
git pull

echo "==> Updating SCCS version strings..."
/usr/local/bin/bash ./scripts/updateSCCSVersions

echo "==> Preparing build environment for $FREEBSD_TRIPLET..."
cd "$BUILD_DIR"

# SAFETY CHECK: Ensure the script is explicitly inside the designated build directory
if [ "$(pwd)" != "$BUILD_DIR" ]; then
    echo "ERROR: Current directory $(pwd) does not match expected BUILD_DIR!"
    echo "Aborting script to prevent accidental deletion."
    exit 1
fi

echo "==> Re-synchronizing clean local plugin layout..."
# Copy fresh master lists from the parent directory down into our active workspace
cp "$TEMPLATE_DIR/plugins.int" ./plugins.int
cp "$TEMPLATE_DIR/plugins.ext" ./plugins.ext

echo "==> Dropping Linux-only CameraPlugin definitions..."
# Using primitive string matching via grep ensures we strip the plugin without breaking sed syntax
grep -v "CameraPlugin" plugins.int > plugins.int.tmp && mv plugins.int.tmp plugins.int || true
grep -v "CameraPlugin" plugins.ext > plugins.ext.tmp && mv plugins.ext.tmp plugins.ext || true

echo "==> Clearing out old configuration caches..."
if [ -f Makefile ]; then
    rm -f Makefile
fi
echo ""
echo ""
echo "============================"
echo "FREEBSD COMPILATION PATCHES"
echo "============================"
export CC="clang"
export MAKE="gmake"

# Passes correct FreeBSD configurations to the compiler
export CFLAGS="-I/usr/local/include -I/usr/local/include/X11 -DCOMPAT_BSD"
export LDFLAGS="-L/usr/local/lib -liconv -Wl,-export-dynamic"

echo "==> Running cross-platform configuration engine..."
../../../../platforms/unix/config/configure \
  --host="$FREEBSD_TRIPLET" \
  --target="$FREEBSD_TRIPLET" \
  --with-src=src/spur64.cog \
  --with-x

echo "==> Injecting Makefile Typo Correction and config.h Engine Overrides..."
if [ -f vm/Makefile ]; then
    sed -i '' 's/wildcard \/home/$(wildcard \/home/g' vm/Makefile || true
fi

# 2. Hardcode the JIT targets to the top of the generated config.h file.
# This bypasses the sub-makefile variable scrubbing entirely.
if [ -f config.h ]; then
    echo "==> Injecting JIT macros into config.h..."
    printf "#define DEBUGVM 0\n#define COGMTVM 0\n$(cat config.h)" > config.h
fi

# 3. Fix UnixOSProcessPlugin type conversion crash
# Forcefully typecast the broken malloc pointer assignment to an integer type (sqInt)
OS_PROCESS_SRC="$VM_SRC/src/plugins/UnixOSProcessPlugin/UnixOSProcessPlugin.c"
if [ -f "$OS_PROCESS_SRC" ]; then
    echo "==> Patching UnixOSProcessPlugin.c clang integer conversion compliance..."
    sed -i '' 's/ifNilSqInt = (sigstack.ss_sp = malloc/ifNilSqInt = (sqInt)(sigstack.ss_sp = malloc/g' "$OS_PROCESS_SRC"
fi
echo "-----------------------------------------------------"
echo "==> Compiling the fresh native binary with gmake..."
echo "-----------------------------------------------------"
gmake -j1
echo ""
echo "========================="
echo "==> VM Update Complete!"
echo "========================="

# =====================================================================
# FREEBSD COMPILATION NOTES & FUTURE MAINTENANCE GUIDE
# =====================================================================
# This custom script adapts the OpenSmalltalk-VM Unix/Linux template 
# pipeline to build natively on FreeBSD using Clang Or GCC. 
#
# WHY THE SPECIFIC PATCHES EXIST:
# 1. CameraPlugin Strip: 
#    The plugin explicitly imports <asm/types.h> and V4L2 headers. 
#    These are Linux-kernel specific frameworks and will violently crash 
#    on FreeBSD's subsystem layout. Strip them before configuring.
#
# 2. CC="clang" & -Wl,-export-dynamic:
#    Upstream configure files prioritize "gcc". We lock in "clang" and 
#    force symbol exportation. Without -export-dynamic, the core VM 
#    hides its symbols, causing dynamic library drivers (like 
#    vm-display-X11.so) to crash at runtime with:
#    "Undefined symbol: mainThreadIsIdle"
#
# 3. The "config.h" Injection Hack (DEBUGVM / COGMTVM):
#    The VMMaker JIT compiler translation files (cogit.c) require 
#    macro mappings to distinguish production vs debug layouts. 
#    Because the internal sub-Makefiles explicitly wipe and reset 
#    environmental CFLAGS during execution, appending these variables 
#    via standard terminal wrappers fails. Forcing definitions straight 
#    into the generated 'config.h' bypasses this scrubbing mechanism.
#
# 4. The Makefile "wildcard" Sed Script:
#    Fixes an upstream syntax typo where the GNU Make macro wrapper 
#    sign "$"" was omitted from the autoconf output template.

# 5. UnixOSProcessPlugin Patching:
#    Modern Clang on FreeBSD completely rejects void pointer to long integer
#    assignments without type declarations, crashing on the sigstack allocation line.
#
# ---------------------------------------------------------------------
# POTENTIAL FUTURE BREAKPOINTS (WHAT TO WATCH OUT FOR ON GIT PULL):
# ---------------------------------------------------------------------
# A. Changing Source Directory Layouts:
#    If the core translation source updates (e.g., migrating from 
#    "src/spur64.cog" to a newer generation scheme like "sista"), 
#    the code generator folder paths will change. You will need to 
#    update the "--with-src=" parameter inside the configure statement.
#
# B. Introduction of New Linux-Centric Plugins:
#    If upstream contributors commit new plugins utilizing systemd, 
#    epoll, or V4L2 hooks, those plugins will crash during compiling 
#    similarly to CameraPlugin. You will need to extend your 'grep -v' 
#    filters to drop them from "plugins.int" and "plugins.ext".
#
# C. Switch to CMake or Meson:
#    There is ongoing, intermittent community movement toward replacing 
#    the legacy Autotools framework ("configure" and "Makefile.in") 
#    with modern meta-build engines. If a future pull drops the 
#    "configure" layout engine entirely, this script will stop working 
#    and will need to be refactored to pass targets via CMake options.
# =====================================================================