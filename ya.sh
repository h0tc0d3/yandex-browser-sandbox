#!/usr/bin/env bash
# Yandex Browser in bubblewrap (Linux, Wayland).
# YA_BROWSER       executable (default: yandex-browser)
# YA_PROFILE_DIR   persistent profile (default: ~/.config/yandex-sandbox)
# YA_SHARE_DIR     persistent downloads/uploads (default: ~/Downloads/yandex-sandbox)
#                  Both sandbox paths must be separate subdirectories of HOME.
#                  Symlink targets must also be inside HOME.
# YA_GPU=0         disable access to host GPU devices (default: 1)
# YA_AUDIO=0       disable direct audio sockets (default: 1)
# YA_PORTALS=0     disable Desktop portal access (default: 1)
# YA_DBUS_LOG=1    log filtered D-Bus traffic (default: 0)
# YA_CHECK=1       run a filesystem/namespace smoke test instead of the browser
# YA_SECCOMP_STRICT=1  also block ptrace and process_vm_readv (may break crash dumps)
# Requires Python 3 and libseccomp.so.2; native x86_64/aarch64 only.
# Usage: ./ya.sh [browser arguments / URLs]

set -euo pipefail
umask 077

# Shared launcher state (used by the setup functions and EXIT trap).
work_dir=''
proxy_pid=''
browser_pid=''
args=()
run=()


# Logging and preflight
# --------------------------------------------------------------------------

log() {
    printf 'ya-sandbox: %s\n' "$*" >&2
}

die() {
    log "$*"
    exit 1
}

warn() {
    log "warning: $*"
}

check_requirements() {
    local tool var

    (( EUID != 0 )) || die 'Do not run this script as root or with sudo.'
    for tool in bwrap realpath stat mktemp flock sha256sum id mkdir rm sleep python3; do
        command -v "$tool" >/dev/null || die "Required command not found: $tool"
    done
    for var in YA_GPU YA_AUDIO YA_PORTALS YA_DBUS_LOG YA_CHECK YA_SECCOMP_STRICT; do
        case ${!var:-0} in
            0|1)
                ;;
            *)
                die "$var must be 0 or 1"
                ;;
        esac
    done
}


# Persistent directories
# --------------------------------------------------------------------------

resolve_home() {
    # Canonicalize before creating or mounting anything. Never bind all of HOME.
    [[ -n ${HOME:-} && $HOME == /* && -d $HOME ]] || die 'Invalid HOME.'
    HOST_HOME=$(realpath -e -- "$HOME") || die 'Cannot resolve HOME.'
    # Keep system trees and sandbox runtime paths separate from the private home.
    case $HOST_HOME in
        /home/*|/var/home/*) ;;
        *) die "Unsupported HOME location: $HOST_HOME (expected /home or /var/home)." ;;
    esac
    [[ -O $HOST_HOME ]] || die 'HOME must be owned by the current user.'
}

inside_home() {
    [[ $1 == "$HOST_HOME/"* ]]
}

paths_overlap() {
    [[ $1 == "$2" || $1 == "$2/"* || $2 == "$1/"* ]]
}

# Keep the logical mount destination separate from the canonical host source.
resolve_destination() {
    local path=$1
    local resolved

    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* ]] || die "Invalid directory path: $path"
    resolved=$(realpath -ms -- "$path") || die "Cannot normalize: $path"
    inside_home "$resolved" || die "Sandbox destination must be inside HOME: $resolved"
    printf '%s\n' "$resolved"
}

resolve_source() {
    local path=$1
    local resolved

    resolved=$(realpath -m -- "$path") || die "Cannot resolve: $path"
    [[ $resolved != *$'\n'* && $resolved != *$'\r'* ]] || die 'Invalid resolved directory path.'
    inside_home "$resolved" || die "External directory not allowed: $resolved"
    printf '%s\n' "$resolved"
}

prepare_persistent_dirs() {
    local path mode

    PROFILE_DIR=$(resolve_destination "${YA_PROFILE_DIR:-$HOST_HOME/.config/yandex-sandbox}") || exit 1
    SHARE_DIR=$(resolve_destination "${YA_SHARE_DIR:-$HOST_HOME/Downloads/yandex-sandbox}") || exit 1
    PROFILE_SOURCE=$(resolve_source "$PROFILE_DIR") || exit 1
    SHARE_SOURCE=$(resolve_source "$SHARE_DIR") || exit 1
    paths_overlap "$PROFILE_DIR" "$SHARE_DIR" && die 'Profile and shared destinations must not overlap.'
    paths_overlap "$PROFILE_SOURCE" "$SHARE_SOURCE" && die 'Profile and shared sources must not overlap.'
    # Check both the mount destinations and their canonical sources.
    for path in "$PROFILE_DIR" "$SHARE_DIR" "$PROFILE_SOURCE" "$SHARE_SOURCE"; do
        case $path in
            "$HOST_HOME"|"$HOST_HOME/.config"|"$HOST_HOME/.local"|"$HOST_HOME/.cache"|\
            "$HOST_HOME/.ssh"|"$HOST_HOME/.gnupg"|"$HOST_HOME/.ssh/"*|"$HOST_HOME/.gnupg/"*)
                die "Unsafe persistent directory: $path" ;;
        esac
    done
    mkdir -p -m 700 -- "$PROFILE_SOURCE" "$SHARE_SOURCE"
    for path in "$PROFILE_SOURCE" "$SHARE_SOURCE"; do
        [[ -d $path && -O $path && -w $path && -x $path ]] ||
            die "Directory must be owned and writable: $path"
        [[ $(realpath -e -- "$path") == "$path" ]] ||
            die "Directory changed while preparing it: $path"
        mode=$(stat -c '%a' -- "$path")
        if (( (8#$mode & 0077) != 0 )); then
            warn "Permissions $mode on $path; consider chmod 700 (not changed automatically)."
        fi
    done
    [[ $(realpath -e -- "$PROFILE_DIR") == "$PROFILE_SOURCE" ]] ||
        die 'Profile symlink changed during setup.'
    [[ $(realpath -e -- "$SHARE_DIR") == "$SHARE_SOURCE" ]] ||
        die 'Shared directory symlink changed during setup.'
}


# Runtime, Wayland and browser arguments
# --------------------------------------------------------------------------

resolve_runtime() {
    HOST_RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$UID}
    [[ $HOST_RUNTIME == /* && -d $HOST_RUNTIME && -O $HOST_RUNTIME ]] ||
        die "Invalid XDG_RUNTIME_DIR: $HOST_RUNTIME"
    HOST_RUNTIME=$(realpath -e -- "$HOST_RUNTIME")
    [[ $(stat -c '%a' -- "$HOST_RUNTIME") == 700 ]] ||
        die "XDG_RUNTIME_DIR must have permissions 0700: $HOST_RUNTIME"
    RUNTIME_DIR=/run/user/$UID
}

resolve_wayland() {
    local sock

    # Respect an explicitly supplied Wayland socket, including absolute paths.
    wayland_path=''
    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        case $WAYLAND_DISPLAY in
            /*) wayland_path=$WAYLAND_DISPLAY ;;
            *)  wayland_path=$HOST_RUNTIME/$WAYLAND_DISPLAY ;;
        esac
        [[ -S $wayland_path ]] || die "Wayland socket does not exist: $wayland_path"
    else
        for sock in "$HOST_RUNTIME"/wayland-*; do
            if [[ -S $sock ]]; then
                wayland_path=$sock
                break
            fi
        done
        [[ -n $wayland_path ]] || die "No Wayland socket in $HOST_RUNTIME"
    fi
    wayland_path=$(realpath -e -- "$wayland_path")
}

resolve_browser() {
    local BROWSER

    BROWSER=${YA_BROWSER:-yandex-browser}
    BROWSER_PATH=''
    if [[ ${YA_CHECK:-0} != 1 ]]; then
        BROWSER_PATH=$(type -P -- "$BROWSER") || die "Browser executable not found: $BROWSER"
        BROWSER_PATH=$(realpath -e -- "$BROWSER_PATH") || die 'Cannot resolve browser executable.'
        [[ -f $BROWSER_PATH && -x $BROWSER_PATH ]] || die "Not an executable file: $BROWSER_PATH"
        case $BROWSER_PATH in
            /usr/*|/bin/*|/opt/yandex/*) ;;
            *) die "Browser outside mounted system trees: $BROWSER_PATH" ;;
        esac
    fi
}

validate_browser_args() {
    local arg

    # Protect launcher invariants. Arguments after -- are positional URLs/files.
    for arg in "$@"; do
        [[ $arg == -- ]] && break
        case $arg in
            --user-data-dir|--user-data-dir=*|\
            --password-store|--password-store=*|\
            --ozone-platform|--ozone-platform=*|\
            --no-sandbox|--no-sandbox=*|\
            --disable-*-sandbox|--disable-*-sandbox=*|\
            --disable-seccomp-filter-sandbox|--disable-seccomp-filter-sandbox=*|\
            --single-process|--single-process=*)
                die "Conflicting or unsafe browser argument: $arg" ;;
        esac
    done
}


# Launcher lifecycle
# --------------------------------------------------------------------------

lock_profile() {
    local lock_key

    # One launcher per profile; lock lives outside the browser's writable mounts.
    # flock is advisory: other launchers that do not use this lock are not covered.
    lock_key=$(printf '%s' "$PROFILE_SOURCE" | sha256sum)
    lock_key=${lock_key%% *}
    exec 9>>"$HOST_RUNTIME/ya-profile-$lock_key.lock"
    flock -n 9 || die "Profile already in use by another sandbox launcher: $PROFILE_DIR"
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $browser_pid ]]; then
        kill -TERM "$browser_pid" 2>/dev/null || true
        wait "$browser_pid" 2>/dev/null || true
    fi
    if [[ -n $proxy_pid ]]; then
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
    fi
    if [[ -n $work_dir ]]; then
        rm -rf -- "$work_dir" || true
    fi
    exit "$status"
}

prepare_workspace() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    work_dir=$(mktemp -d -- "$HOST_RUNTIME/ya-sandbox.XXXXXXXX")
}


# Seccomp-BPF policy
# --------------------------------------------------------------------------

# Compile a native-ABI classic BPF filter with libseccomp. No compiler, root,
# Python seccomp bindings or precompiled architecture-specific blob required.
# Fail closed: never start bwrap if filter creation/export fails.
compile_seccomp() {
    python3 -I - "$work_dir/seccomp.bpf" "${YA_SECCOMP_STRICT:-0}" \
        <<'PY_SECCOMP' || die 'Seccomp generation failed; browser not started.'
import ctypes as C
import errno
import os
import platform
import sys

ALLOW = 0x7FFF0000
ERRNO = 0x00050000
KILL_PROCESS = 0x80000000
ACT_BADARCH = 2
CMP_EQ = 4
CMP_MASKED_EQ = 7


class Compare(C.Structure):
    _fields_ = [
        ("arg", C.c_uint),
        ("op", C.c_int),
        ("datum_a", C.c_uint64),
        ("datum_b", C.c_uint64),
    ]


def main():
    if platform.machine() not in ("x86_64", "aarch64") or C.sizeof(C.c_void_p) != 8:
        raise RuntimeError("only native 64-bit x86_64/aarch64 is supported")
    lib = C.CDLL("libseccomp.so.2")

    def bind(name, result, *args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, list(args)
        return fn

    init = bind("seccomp_init", C.c_void_p, C.c_uint32)
    release = bind("seccomp_release", None, C.c_void_p)
    attr = bind("seccomp_attr_set", C.c_int, C.c_void_p, C.c_int, C.c_uint32)
    resolve = bind("seccomp_syscall_resolve_name", C.c_int, C.c_char_p)
    rule = bind(
        "seccomp_rule_add_exact_array",
        C.c_int,
        C.c_void_p,
        C.c_uint32,
        C.c_int,
        C.c_uint,
        C.POINTER(Compare),
    )
    export = bind("seccomp_export_bpf", C.c_int, C.c_void_p, C.c_int)

    def check(rc, label):
        if rc != 0:
            raise RuntimeError(f"{label}: {os.strerror(-rc) if rc < 0 else rc}")

    ctx = init(ALLOW)
    if not ctx:
        raise RuntimeError("seccomp_init failed")
    count = 0
    try:
        # Native ABI only; reject compat ABIs rather than leave a second ABI
        # unfiltered. libseccomp also checks the x32 syscall-number range.
        check(attr(ctx, ACT_BADARCH, KILL_PROCESS), "bad-architecture action")

        def deny(name, error=errno.EPERM, *comparisons):
            nonlocal count
            nr = resolve(name.encode("ascii"))
            if nr == -1:
                raise RuntimeError(f"unknown syscall {name}; update libseccomp")
            if nr < 0:
                # libseccomp knows the name, but it has no native syscall here.
                return
            array = (
                (Compare * len(comparisons))(*comparisons)
                if comparisons
                else None
            )
            check(rule(ctx, ERRNO | error, nr, len(comparisons), array), name)
            count += 1

        # No host kernel administration, keyrings, BPF, perf, cross-process
        # writes, file-handle opens, or alternate mount API after setup.
        for name in """
            bpf perf_event_open userfaultfd
            add_key request_key keyctl
            init_module finit_module delete_module kexec_load kexec_file_load
            reboot swapon swapoff acct quotactl syslog
            settimeofday clock_settime clock_adjtime adjtimex
            iopl ioperm open_by_handle_at name_to_handle_at
            process_vm_writev pidfd_getfd kcmp
            mount umount2 pivot_root fsopen fsconfig fsmount fspick
            open_tree move_mount mount_setattr
            fanotify_init fanotify_mark
        """.split():
            deny(name)

        # ENOSYS permits normal fallback when a library probes an optional API.
        # clone3's pointer arguments cannot be inspected by classic seccomp;
        # keep legacy clone/unshare available for Chromium's nested sandbox.
        for name in ("io_uring_setup", "io_uring_enter", "io_uring_register", "clone3"):
            deny(name, errno.ENOSYS)

        # Deny raw packet, vsock and XDP sockets. Preserve UNIX, INET/INET6
        # (including DNS/QUIC/WebRTC), and NETLINK for network discovery.
        for family in (17, 40, 44):  # AF_PACKET, AF_VSOCK, AF_XDP (Linux UAPI)
            deny("socket", errno.EPERM, Compare(0, CMP_EQ, family, 0))
        for family in (2, 10):  # AF_INET, AF_INET6; SOCK_RAW = 3
            deny(
                "socket",
                errno.EPERM,
                Compare(0, CMP_EQ, family, 0),
                Compare(1, CMP_MASKED_EQ, 0xF, 3),
            )
        for request in (0x5412, 0x541C):  # TIOCSTI, TIOCLINUX
            deny("ioctl", errno.EPERM, Compare(1, CMP_MASKED_EQ, 0xFFFFFFFF, request))

        # Chromium crash reporting may use these; leave them to its internal
        # sandbox in the default mode. Strict mode sacrifices this compatibility.
        if sys.argv[2] == "1":
            deny("ptrace")
            deny("process_vm_readv")

        # chroot, seccomp, prctl, clone, unshare and setns intentionally remain
        # available. This is defense in depth, not a syscall allowlist.
        with open(sys.argv[1], "xb", buffering=0) as out:
            check(export(ctx, out.fileno()), "seccomp_export_bpf")
        size = os.path.getsize(sys.argv[1])
        if not size or size % 8 or size > 4096 * 8:
            raise RuntimeError(f"invalid classic BPF size: {size}")
        print(
            f"ya-sandbox: seccomp: {count} rules, {size // 8} BPF instructions",
            file=sys.stderr,
        )
    finally:
        release(ctx)


try:
    main()
except (OSError, RuntimeError, AttributeError) as exc:
    sys.exit(f"ya-sandbox: seccomp: {exc}")
PY_SECCOMP
}


# Bubblewrap arguments
# --------------------------------------------------------------------------

write_download_config() {
    local xdg_download

    # Set the default download directory for software using XDG user dirs.
    # Explicit browser download preferences saved in an existing profile take priority.
    xdg_download=$SHARE_DIR
    xdg_download=${xdg_download//\\/\\\\}
    xdg_download=${xdg_download//\"/\\\"}
    xdg_download=${xdg_download//\$/\\\$}
    xdg_download=${xdg_download//\`/\\\`}
    printf 'XDG_DOWNLOAD_DIR="%s"\n' "$xdg_download" > "$work_dir/user-dirs.dirs"
}

add_base_mounts() {
    local d

    args=(
        --unshare-all
        --unshare-user
        --share-net
        --die-with-parent
        --new-session
        --clearenv
        --seccomp 8
        --ro-bind /usr /usr
        --ro-bind-try /opt/yandex /opt/yandex
        --ro-bind /sys /sys
        --proc /proc
        --dev /dev
        --perms 1777 --tmpfs /dev/shm
        --perms 1777 --tmpfs /tmp
        --dir /etc
    )

    # Support merged-/usr and traditional layouts.
    for d in bin sbin lib lib32 lib64; do
        if [[ -L /$d ]]; then
            args+=(--symlink "$(readlink "/$d")" "/$d")
        elif [[ -d /$d ]]; then
            args+=(--ro-bind "/$d" "/$d")
        fi
    done
}

add_system_config() {
    local path

    # Allowlist system configuration, not the complete /etc tree.
    # Binding resolv.conf itself follows its host symlink, without mounting /run services.
    [[ -r /etc/resolv.conf ]] || warn '/etc/resolv.conf is missing or unreadable; DNS may fail.'
    local -a system_paths=(
        /etc/passwd
        /etc/group
        /etc/nsswitch.conf
        /etc/hosts
        /etc/hostname
        /etc/resolv.conf
        /etc/host.conf
        /etc/gai.conf
        /etc/services
        /etc/protocols
        /etc/ld.so.cache
        /etc/ld.so.conf
        /etc/ld.so.conf.d
        /etc/localtime
        /etc/timezone
        /etc/locale.conf
        /etc/locale.alias
        /etc/fonts
        /etc/ssl
        /etc/pki
        /etc/ca-certificates
        /etc/crypto-policies
        /etc/alternatives
        /etc/os-release
        /etc/machine-id
        /etc/pulse
        /etc/pipewire
        /etc/drirc
        /etc/vulkan
        /etc/glvnd
        /var/cache/fontconfig
    )

    for path in "${system_paths[@]}"; do
        if [[ -e $path ]]; then
            args+=(--ro-bind "$path" "$path")
        fi
    done
}

add_home_and_runtime() {
    # Empty HOME and runtime; never expose the original working directory.
    args+=(
        --perms 0700 --tmpfs "$HOST_HOME"
        --bind "$PROFILE_SOURCE" "$PROFILE_DIR"
        --bind "$SHARE_SOURCE" "$SHARE_DIR"
        --perms 0700 --tmpfs "$RUNTIME_DIR"
        --ro-bind "$wayland_path" "$RUNTIME_DIR/wayland-0"
        --perms 0700 --dir /tmp/ya-config
        --ro-bind "$work_dir/user-dirs.dirs" /tmp/ya-config/user-dirs.dirs
        --chdir "$HOST_HOME"
        --setenv PATH /usr/local/bin:/usr/bin:/bin
        --setenv HOME "$HOST_HOME"
        --setenv USER "$(id -un)"
        --setenv LOGNAME "$(id -un)"
        --setenv XDG_RUNTIME_DIR "$RUNTIME_DIR"
        --setenv XDG_CONFIG_HOME /tmp/ya-config
        --setenv XDG_SESSION_TYPE wayland
        --setenv WAYLAND_DISPLAY wayland-0
        --setenv TMPDIR /tmp
        --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$RUNTIME_DIR/no-session-bus"
    )
}

add_personal_fonts() {
    local fonts

    # Do not mount personal fonts on top of a writable persistent directory.
    fonts=$HOST_HOME/.local/share/fonts
    if [[ -d $fonts && ! -L $fonts ]] && [[ $(realpath -e -- "$fonts") == "$fonts" ]] &&
       ! paths_overlap "$fonts" "$PROFILE_DIR" && ! paths_overlap "$fonts" "$SHARE_DIR" &&
       ! paths_overlap "$fonts" "$PROFILE_SOURCE" && ! paths_overlap "$fonts" "$SHARE_SOURCE"; then
        args+=(--ro-bind "$fonts" "$fonts")
    fi
}

add_gpu_devices() {
    local dev

    if [[ ${YA_GPU:-1} == 1 ]]; then
        args+=(--dev-bind-try /dev/dri /dev/dri)
        for dev in \
            /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-modeset \
            /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-caps; do
            if [[ -c $dev || -d $dev ]]; then
                args+=(--dev-bind "$dev" "$dev")
            fi
        done
    fi
}

add_audio_sockets() {
    if [[ ${YA_AUDIO:-1} == 1 ]]; then
        # Expose the required sockets only, not the entire PulseAudio directory.
        if [[ -S $HOST_RUNTIME/pulse/native ]]; then
            args+=(
                --ro-bind "$HOST_RUNTIME/pulse/native" "$RUNTIME_DIR/pulse/native"
                --setenv PULSE_SERVER "unix:$RUNTIME_DIR/pulse/native"
            )
        fi
        if [[ -S $HOST_RUNTIME/pipewire-0 ]]; then
            args+=(--ro-bind "$HOST_RUNTIME/pipewire-0" "$RUNTIME_DIR/pipewire-0")
        fi
    fi
}

add_locale_environment() {
    local v

    for v in \
        LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES LC_NUMERIC LC_TIME \
        LC_COLLATE LC_MONETARY TZ XDG_CURRENT_DESKTOP XCURSOR_THEME XCURSOR_SIZE; do
        if [[ -n ${!v:-} ]]; then
            args+=(--setenv "$v" "${!v}")
        fi
    done
}


# Filtered D-Bus proxy
# --------------------------------------------------------------------------

start_dbus_proxy() {
    local host_bus i
    local -a proxy_opts=()

    # No unfiltered host session/system bus is mounted. Portal access is optional.
    if command -v xdg-dbus-proxy >/dev/null; then
        host_bus=${DBUS_SESSION_BUS_ADDRESS:-}
        if [[ -z $host_bus && -S $HOST_RUNTIME/bus ]]; then
            host_bus=unix:path=$HOST_RUNTIME/bus
        fi
        if [[ -n $host_bus ]]; then
            proxy_opts=(
                --filter
                --talk=org.freedesktop.Notifications
                --talk=org.freedesktop.ScreenSaver
                --own='org.mpris.MediaPlayer2.*'
            )
            if [[ ${YA_PORTALS:-1} == 1 ]]; then
                proxy_opts+=(--talk=org.freedesktop.portal.Desktop)
            fi
            if [[ ${YA_DBUS_LOG:-0} == 1 ]]; then
                proxy_opts+=(--log)
            fi
            xdg-dbus-proxy "$host_bus" "$work_dir/bus" "${proxy_opts[@]}" 9>&- &
            proxy_pid=$!
            for ((i = 0; i < 50; i++)); do
                kill -0 "$proxy_pid" 2>/dev/null || die 'xdg-dbus-proxy exited unexpectedly.'
                [[ -S $work_dir/bus ]] && break
                sleep 0.1
            done
            [[ -S $work_dir/bus ]] || die 'D-Bus proxy startup timed out.'
            args+=(
                --ro-bind "$work_dir/bus" "$RUNTIME_DIR/bus"
                --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$RUNTIME_DIR/bus"
            )
        else
            warn 'No host session bus found; continuing without D-Bus.'
        fi
    else
        warn 'xdg-dbus-proxy not installed; continuing without D-Bus.'
    fi
}


# Outer sandbox self-test
# --------------------------------------------------------------------------

build_check_command() {
    local smoke_test

    # Tests the outer sandbox, not Chromium's internal sandbox or GUI.
    # read returns nonzero at EOF; no NUL delimiter is expected in this text.
    read -r -d '' smoke_test <<'BASH_CHECK' || true
test "$(id -u)" != 0
test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
test -w /dev/shm
test -w "$1"
test -w "$2"
test ! -e /etc/shadow
test ! -e "$HOME/.ssh"
test ! -e "$HOME/.gnupg"
test ! -e /run/dbus/system_bus_socket
test -r "$XDG_CONFIG_HOME/user-dirs.dirs"
# Kernel status plus functional probes; status alone could describe
# an inherited filter rather than the policy we generated.
python3 -I - <<'PY_CHECK'
import ctypes as C
import errno
import os
import socket

status = dict(line.split(":", 1) for line in open("/proc/self/status") if ":" in line)
assert status["Seccomp"].strip() == "2", "Seccomp filter mode inactive"
assert status["NoNewPrivs"].strip() == "1", "NoNewPrivs inactive"
lib = C.CDLL("libseccomp.so.2")
lib.seccomp_syscall_resolve_name.argtypes = [C.c_char_p]
lib.seccomp_syscall_resolve_name.restype = C.c_int
syscall = C.CDLL(None, use_errno=True).syscall
syscall.restype = C.c_long
for name, expected in (
    (b"io_uring_setup", errno.ENOSYS),
    (b"clone3", errno.ENOSYS),
    (b"keyctl", errno.EPERM),
):
    nr = lib.seccomp_syscall_resolve_name(name)
    assert nr >= 0, name
    C.set_errno(0)
    result = syscall(
        C.c_long(nr),
        C.c_long(-1),
        C.c_long(0),
        C.c_long(0),
        C.c_long(0),
        C.c_long(0),
        C.c_long(0),
    )
    assert result == -1 and C.get_errno() == expected, (name, result, C.get_errno())
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
except OSError as exc:
    assert exc.errno == errno.EPERM, exc
else:
    s.close()
    raise RuntimeError("raw IPv4 socket unexpectedly allowed")
with socket.socket(socket.AF_INET, socket.SOCK_STREAM), \
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM), \
        socket.socketpair()[0]:
    pass
pid = os.fork()
if pid == 0:
    os._exit(0)
assert os.waitpid(pid, 0)[1] == 0
print("Seccomp mode 2, NoNewPrivs=1; syscall/socket/fork probes passed.")
PY_CHECK
printf "Outer sandbox smoke test passed.\nHOME=%s\nProfile=%s\nShare=%s\n" "$HOME" "$1" "$2"
BASH_CHECK

    run=(/bin/bash -ec "$smoke_test" ya-check "$PROFILE_DIR" "$SHARE_DIR")
}


# Browser launch
# --------------------------------------------------------------------------

build_run_command() {
    if [[ ${YA_CHECK:-0} == 1 ]]; then
        build_check_command
        return
    fi

    run=(
        "$BROWSER_PATH"
        --user-data-dir="$PROFILE_DIR"
        --password-store=basic
        --ozone-platform=wayland
    )
    if [[ ${YA_GPU:-1} == 0 ]]; then
        run+=(--disable-gpu)
    fi
    run+=("$@")
}

run_sandbox() {
    local status

    # Keep the launcher alive while bwrap runs; close its lock FD in children.
    # No automatic --no-sandbox fallback: a Chromium sandbox failure must be fixed.
    bwrap "${args[@]}" -- "${run[@]}" 8<"$work_dir/seccomp.bpf" 9>&- <&0 &
    browser_pid=$!
    status=0
    wait "$browser_pid" || status=$?
    browser_pid=''
    if (( status != 0 )); then
        warn "Sandbox exited with status $status. Check the preceding bwrap/browser diagnostics."
    fi
    exit "$status"
}

main() {
    check_requirements
    resolve_home
    prepare_persistent_dirs
    resolve_runtime
    resolve_wayland
    resolve_browser
    validate_browser_args "$@"

    lock_profile
    prepare_workspace
    compile_seccomp
    write_download_config

    add_base_mounts
    add_system_config
    add_home_and_runtime
    add_personal_fonts
    add_gpu_devices
    add_audio_sockets
    add_locale_environment
    start_dbus_proxy

    build_run_command "$@"
    run_sandbox
}

main "$@"
