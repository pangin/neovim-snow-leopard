# Mac OS X Snow Leopard backport

This branch backports Neovim 0.11 to Mac OS X 10.6.8 on 32-bit Intel Macs.
It targets Darwin 10.8.0 (`i386`) and is intended for MacPorts installed under
`/opt/local`. It installs into `$HOME/.local/nvim` and needs no `sudo`.

MacPorts gates its `neovim` port at `darwin >= 15` without a stated reason,
while every dependency Neovim needs (libuv, LuaJIT, luv, unibilium,
tree-sitter, lpeg, utf8proc) is `platforms: darwin` with no floor. This branch
uses Neovim's own bundled-dependency build, so those come from source too.

## Target

- Mac OS X 10.6.8 / Darwin 10.8.0 / `i386`
- Intel Core Duo 1.83 GHz, 2 cores, no 64-bit support (`hw.cpu64bit_capable: 0`)
- 2 GB RAM

## Tested toolchain

- MacPorts 2.12.6
- `clang-16 @16.0.6_9`
- `ld64-274 @274.2_0+llvm34` (see the linker note below)
- `cmake @3.31.12_0`
- `gmake @4.4.1_1`
- `legacy-support @1.5.2_0`
- `gettext @1.0_0`, `pkgconfig @0.29.2_0`
- `git @2.55.0_1`, `curl @8.22.0_0` (the system `curl` cannot negotiate TLS 1.2)

Install the build dependencies with MacPorts:

```sh
sudo /opt/local/bin/port install clang-16 ld64-274 cmake gmake legacy-support gettext pkgconfig git curl
```

`ninja` is optional; the build uses Unix Makefiles.

## Build

```sh
./build-snow-leopard.sh deps      # bundled dependencies, with the patches below
./build-snow-leopard.sh nvim      # Neovim itself
./build-snow-leopard.sh install   # into $HOME/.local/nvim
~/.local/nvim/bin/nvim --version
```

The script is resumable. Node.js builds running on the same machine are
paused for the duration and resumed afterwards, because 2 GB cannot hold two
compilers' worth of working set.

## Compatibility changes

Bundled dependencies (applied to the extracted sources under
`.deps/build/src/`; the script handles this):

- **LuaJIT**: define `O_CLOEXEC` as 0 in `lj_prng.c`. The flag arrived in
  10.7. The descriptor is `/dev/urandom`, read once and closed at once.
- **libuv**: compile out source-specific multicast. `ip_mreq_source`,
  `group_source_req` and `IP_ADD_SOURCE_MEMBERSHIP` arrived in 10.7; libuv
  already returns `UV_ENOSYS` on platforms without them, so this only selects
  that path (`UV_NO_SSM`).
- **libuv**: select the fork/exec spawn path. The Apple `posix_spawn` path
  needs `posix_spawn_file_actions_addinherit_np` and
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, both 10.7 and both absent from Snow Leopard's
  `libSystem`. libuv describes that path as a Big Sur performance workaround
  (`UV_NO_POSIX_SPAWN`).
- **libuv**: gate the `recvmsg_x` / `sendmsg_x` batch paths on
  `MAC_OS_X_VERSION_MIN_REQUIRED >= 101000`. These are Apple-private batch
  syscalls that arrived in 10.10; libuv 1.48+ calls them unconditionally on
  Darwin and the link fails with both undefined. Below 10.10 libuv takes the
  same generic `recvmsg`/`sendmsg` path it uses on every other Unix.
  (Node.js 20 bundles libuv 1.46, which predates this code.)

Neovim itself (in-tree, two files):

- `src/nvim/channel.c`: `F_DUPFD_CLOEXEC` arrived in 10.7. Duplicate with
  `F_DUPFD`, then set `FD_CLOEXEC`. Only the embedded-UI path uses it.
- `src/nvim/os/env.c`: `TASK_DEFAULT_APPLICATION` and task category policy
  arrived in 10.9 with App Nap. `os_hint_priority()` is compiled out when the
  constant is absent; there is nothing to opt out of on 10.6.

Supplied by MacPorts `legacy-support`, no source change: `clock_gettime`,
`getentropy`, `strnlen`, `getline`, `fdopendir`, `futimens`. Its include
directory must precede the 2009 system headers because its wrappers use
`#include_next`.

## Build notes

- **Linker.** Neovim links with `-Wl,-export_dynamic`. The `ld` that MacPorts
  `clang-16` invokes here is ld64-127, which predates that option and fails
  with `unknown option: -export_dynamic`. ld64-274 accepts it and produces a
  correct i386 Mach-O, so the link uses `--ld-path=/opt/local/bin/ld-274`.
- **clang 16 and the 10.6 SDK.** The SDK's `scandir` prototype takes non-const
  callback pointers (pre-POSIX-2008). clang 16 made
  `-Wincompatible-function-pointer-types` an error; the pointer ABI is
  identical, so the build passes `-Wno-error=incompatible-function-pointer-types`
  to restore clang 15 behaviour.
- **CMake caches.** Changing compiler or linker flags does not reach a
  dependency whose sub-build was already configured; its `CMakeCache.txt`
  holds the old values. The script removes the affected configure stamps and
  build directories when flags change, and keeps the extracted (patched)
  sources.
- **Detach builds from the SSH session.** `nohup` alone is not enough: with
  stdin still attached to an SSH pipe, `gmake` sleeps the moment the session
  closes. The script redirects stdin from `/dev/null`.
- **Terminal.** Terminal.app on 10.6 has 256 colours and no true colour. Keep
  `termguicolors` off and use a 256-colour scheme (`habamax` ships with
  Neovim).

- **Reinstalling a dependency regenerates Neovim.** Rebuilding libuv after a
  patch re-copies its headers into `.deps/usr/include` with new timestamps,
  and Neovim's generated-header rules depend on them, so the whole of
  `src/nvim` is regenerated and recompiled. Apply all dependency patches
  before the first `nvim` build; the script does.

## Verified behavior

Built and run on the target on 2026-09-20:

```
$ file ~/.local/nvim/bin/nvim
Mach-O executable i386
$ nvim --version | head -3
NVIM v0.11.7
Build type: Release
LuaJIT 2.1.1741730670
```

- `has('nvim-0.11')` is 1 and `vim.treesitter` is present.
- A headless session opened a new file, inserted text and wrote it.
- `vim.fn.system({'echo', 'spawn-ok'})` returned `spawn-ok`, exercising the
  fork/exec spawn path selected by the libuv patch.
- `otool -L` resolves every library: `libMacportsLegacySupport.dylib`,
  CoreServices, `libiconv.2.dylib`, `libintl.8.dylib`, `libSystem.B.dylib`,
  `libutil.dylib`.

Not yet exercised on the target: the terminal UI interactively (the checks
above are headless), and long sessions. Plugin and language-server
verification is tracked in
[snow-leopard-devenv](https://github.com/pangin/snow-leopard-devenv).
