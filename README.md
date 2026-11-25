# Yandex Browser Sandbox

![Терморектальный криптоанализ](./major.png)

A Bash launcher for running Yandex Browser inside [Bubblewrap](https://github.com/containers/bubblewrap) on Linux with Wayland. It adds an outer layer of filesystem, namespace, D-Bus and syscall isolation while preserving the browser's own Chromium sandbox.

## Features

- Temporary, isolated home directory, `/tmp` and runtime directory.
- Separate persistent browser profile and shared downloads/uploads directory.
- Read-only system mounts and an explicit allowlist of host configuration files.
- Native seccomp-BPF filter generated at startup using Python and libseccomp.
- Wayland support with optional GPU, audio and desktop portal access.
- Filtered session D-Bus access through `xdg-dbus-proxy`, when available.
- Advisory per-profile locking and automatic cleanup on normal exit or handled signals.
- Built-in smoke test for the outer sandbox.
- No automatic fallback to `--no-sandbox`.

## Requirements

- Linux on native 64-bit `x86_64` or `aarch64`.
- A running Wayland session.
- An unprivileged user account with a home directory under `/home` or `/var/home`.
- A user-owned `XDG_RUNTIME_DIR` with permissions `0700` (defaults to `/run/user/$UID`).
- Bash, Bubblewrap (`bwrap`), Python 3 and `libseccomp.so.2`.
- Standard Linux utilities: GNU coreutils and `flock` (usually provided by util-linux).
- Yandex Browser installed under `/usr`, `/bin` or `/opt/yandex` (not needed for smoke-test mode).
- Kernel and distribution support for the user namespaces needed by Bubblewrap and Chromium.
- Optional: `xdg-dbus-proxy` for desktop integration.

No compiler or Python seccomp bindings are required. Package names and namespace policies vary by distribution.

## Installation

Place `ya.sh` in a directory of your choice and make it executable:

```sh
chmod +x ya.sh
```

Run it as your regular user from a Wayland session. Do not use `sudo`.

## Usage

```sh
./ya.sh
```

Open a URL:

```sh
./ya.sh https://example.org
```

Pass browser arguments:

```sh
./ya.sh --incognito https://example.org
```

The launcher supplies its own `--user-data-dir`, `--password-store=basic` and `--ozone-platform=wayland` flags. It rejects conflicting options and common sandbox-disabling flags before the `--` argument separator. Only pass trusted browser arguments.

## Configuration

All launcher options are environment variables. Boolean options accept `0` or `1`.

| Variable | Default | Description |
| --- | --- | --- |
| `YA_BROWSER` | `yandex-browser` | Browser executable to resolve through `PATH` (or an executable path). |
| `YA_PROFILE_DIR` | `$HOME/.config/yandex-sandbox` | Persistent browser profile directory. |
| `YA_SHARE_DIR` | `$HOME/Downloads/yandex-sandbox` | Persistent directory for downloads and uploads. |
| `YA_GPU` | `1` | Expose available GPU devices. Set to `0` to omit the device mounts and pass `--disable-gpu`. |
| `YA_AUDIO` | `1` | Expose available PulseAudio and PipeWire sockets. |
| `YA_PORTALS` | `1` | Permit access to `org.freedesktop.portal.Desktop` through the D-Bus proxy. |
| `YA_DBUS_LOG` | `0` | Enable logging of D-Bus proxy traffic. |
| `YA_CHECK` | `0` | Run the outer sandbox smoke test instead of the browser. |
| `YA_SECCOMP_STRICT` | `0` | Also block `ptrace` and `process_vm_readv`; may interfere with crash reporting. |

The launcher also uses `HOME`, `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY` and `DBUS_SESSION_BUS_ADDRESS` from the host environment when applicable. Selected locale and desktop appearance variables are forwarded into the sandbox.

### Custom profile and shared directory

```sh
YA_PROFILE_DIR="$HOME/.config/ya-private" \
YA_SHARE_DIR="$HOME/Downloads/ya-private" \
./ya.sh
```

### Disable optional host integrations

```sh
YA_GPU=0 YA_AUDIO=0 YA_PORTALS=0 ./ya.sh
```

This omits the optional GPU and audio mounts and disables portal access. The Wayland connection, shared network and any available filtered D-Bus proxy remain enabled.

### Enable stricter syscall filtering

```sh
YA_SECCOMP_STRICT=1 ./ya.sh
```

## Persistent data

By default, the following directories are created if missing:

```text
~/.config/yandex-sandbox/      Browser profile
~/Downloads/yandex-sandbox/   Shared files
```

Both directories are mounted read-write at their corresponding paths inside the sandbox. Everything else in the sandbox home is temporary, except any additional read-only mounts such as personal fonts.

Directory rules:

- Both paths must be absolute, distinct subdirectories of the canonical home directory.
- Their canonical sources must also remain inside that home directory. Symlinks to external directories, including `/tmp/cache2tmp-$UID`, are rejected.
- The profile and shared directory must not overlap, either as mount destinations or as resolved sources.
- Broad paths such as the entire home directory, `~/.config`, `~/.local` and `~/.cache`, and paths under `~/.ssh` or `~/.gnupg`, are rejected.
- Sources must be owned by the current user and be writable and searchable. New directories are created with restrictive permissions; permissive existing directories produce a warning rather than being silently changed.

An XDG user-dirs configuration points the default download directory at `YA_SHARE_DIR`. Existing browser download preferences may override it; configure the download location in the browser if necessary. Place files you intend to upload in the shared directory. Enabled desktop portals may provide additional user-authorized file access.

If migrating from a version that supported external cache directories, close the browser and move or copy any persistent data you want to retain to suitable directories inside your home before launching this version. Existing external symlinks must be replaced or redirected to locations within the home directory. The launcher does not migrate or delete old data automatically.

## Isolation model

### Filesystem and namespaces

Bubblewrap creates an isolated environment using namespaces, with the host network namespace explicitly shared. The host home and runtime directory are replaced with temporary filesystems. Only selected paths are mounted from the host, including the persistent directories, read-only system files, the Wayland socket and enabled integrations.

The launcher clears the inherited environment and reconstructs the variables needed by the browser. It does not mount the entire host `/etc`, home directory or runtime directory. Personal fonts may be mounted read-only if their path passes the launcher's checks.

### Seccomp

The launcher generates a native classic BPF filter using libseccomp through Python's `ctypes`. Filter generation must succeed before Bubblewrap starts.

The filter blocks selected high-risk syscalls and operations, including kernel administration, BPF, performance events, keyrings, cross-process memory writes, file-handle opens, mount operations, `io_uring`, raw IP sockets and selected socket families. `clone3` and `io_uring` calls return `ENOSYS` to permit compatible fallbacks. Legacy process creation and namespace operations required by Chromium remain available.

This is a defense-in-depth denylist, not a complete syscall allowlist. Strict mode additionally blocks `ptrace` and `process_vm_readv`.

### Desktop integration

- **Wayland:** the selected compositor socket is exposed inside the isolated runtime directory.
- **GPU:** available DRM and NVIDIA devices may be mounted when enabled.
- **Audio:** available PulseAudio and PipeWire sockets may be exposed when enabled.
- **D-Bus:** the optional proxy permits notifications, screensaver communication, ownership of MPRIS media-player names and, by default, desktop portal communication. The unfiltered host session and system buses are not intentionally mounted.

If the D-Bus proxy is unavailable, the launcher continues without session D-Bus integration. If a proxy is started but fails to initialize, the launcher aborts.

## Testing

Check Bash syntax:

```sh
bash -n ya.sh
```

Run the built-in smoke test from your Wayland session:

```sh
YA_CHECK=1 ./ya.sh
```

The smoke test checks selected filesystem and runtime properties, including writable persistent directories, the Wayland socket, hidden SSH and GnuPG paths, seccomp mode, `NoNewPrivs`, syscall rejection, socket restrictions and process creation.

On success, it reports `Outer sandbox smoke test passed.` This test does not launch Yandex Browser or verify its internal Chromium sandbox, GUI behavior or resistance to sandbox escapes.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `Required command not found` | Install the missing dependency. |
| `Invalid XDG_RUNTIME_DIR` | Run from a normal user session and check the runtime directory ownership and permissions. |
| `No Wayland socket` | Verify that a Wayland compositor is running and `WAYLAND_DISPLAY` is correct. |
| `External directory not allowed` | Check whether the profile or shared path resolves outside your home directory. |
| `Profile already in use` | Close the other launcher using that profile, or choose a separate profile directory. |
| `Seccomp generation failed` | Verify Python 3, `libseccomp.so.2`, supported architecture and syscall support in libseccomp. |
| Bubblewrap or Chromium namespace errors | Check kernel and distribution user-namespace policies. Do not work around these errors by disabling the browser sandbox. |
| Graphics problems | Try `YA_GPU=0`. |
| Audio or desktop integration problems | Check the relevant runtime sockets, host services and optional D-Bus proxy. Try `YA_DBUS_LOG=1` for proxy diagnostics. |
| Crash reporting problems | If strict mode is enabled, try the default `YA_SECCOMP_STRICT=0`. |

## Security considerations

This launcher is an additional isolation layer, not a virtual machine or a guarantee of containment. The browser shares the host kernel and network and can access local network services. The Wayland compositor, optional GPU and audio interfaces, D-Bus proxy and enabled portals are additional trust boundaries.

The persistent directories are deliberately writable by the browser. Do not store sensitive files in them unless you intend the browser to access those files. A compromised browser may modify its own profile or shared data and retain state across restarts.

The browser is launched with `--password-store=basic`; do not assume credentials are protected by the host desktop keyring. Keep the browser, kernel, Bubblewrap and other dependencies updated. Disable optional integrations you do not need, and retain Chromium's internal sandbox.

The profile lock is advisory and only coordinates launchers that use the same locking mechanism. Directory validation reduces accidental exposure but should not be treated as protection against all concurrent filesystem changes by a malicious host process.

For stronger isolation of untrusted software, consider a dedicated virtual machine and a separate network policy.
