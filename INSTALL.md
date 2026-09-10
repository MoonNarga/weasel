# How to Rime with Weasel

## Preparation

  - Install **Visual Studio 2017** for *Desktop development in C++*
    with components *ATL*, *MFC* and *Windows XP support*.
    Visual Studio 2015 or later versions may work with additional configuration.

  - Install dev tools: `git`, `cmake`， `clang-format(>=17.0.6)`

  - Download third-party libraries: `boost(>=1.60.0)`

Optional:

  - install `bash` via *Git for Windows*, for installing data files with `plum`;
  - install `python` for building OpenCC dictionaries;
  - install [NSIS](http://nsis.sourceforge.net/Download) for creating installer.

## Checkout source code

Make sure all git submodules are checked out recursively.

```batch
git clone --recursive https://github.com/rime/weasel.git
```

## Build and Install Weasel

Locate `weasel` source directory.

### Setup build environment

Edit your build environment settings in `env.bat`.
You can create the file by copying `env.bat.template` in the source tree.

Make sure `BOOST_ROOT` is set to the existing path `X:\path\to\boost_<version>`.

When using a different version of Visual Studio or platform toolset, un-comment
lines to set corresponding variables.

Alternatively, start a *Developer Command Prompt* window and set environment
variables directly in the console, before invocation of `build.bat`:

```batch
set BOOST_ROOT=X:\path\to\boost_N_NN_N
```

### Build

```batch
cd weasel
build.bat all
```

Voila.

Installer will be generated in `output\archives` directory.

### Alternative: using prebuilt Rime binaries

If you've already got a copy of prebuilt binaries of librime, you can simply
copy `.dll`s / `.lib`s into `weasel\output` / `weasel\lib` directories
respectively, then build Weasel without the `all` command line option.

```batch
build.bat boost data opencc
build.bat weasel
```

### Local dependency paths for xmake

Copy `xmake.local.lua.example` to `xmake.local.lua` and set `boost_root` to an
external Boost directory. The local file is ignored by Git; only the example is
shared. It defines a Lua table named `weasel_deps`.

`boost_libdir` defaults to `<boost_root>/stage/lib`. `rime_root` defaults to
`librime/dist` (with `include` and `lib` beneath it). Override `rime_libdir` and
`platform_libdir` when using external or architecture-specific libraries. Each
path may be a string or a table keyed by `x64`, `x86`, `arm`, `arm64`, with an
optional `default` entry. Relative paths are resolved from the repository root.
Local settings take precedence over `BOOST_ROOT`; that environment variable
remains supported when `boost_root` is omitted. No Boost directory inside the
repository is assumed. Use libraries built for the selected architecture and
the project's static MSVC runtime (`/MT`).

For editor checks without a Developer Command Prompt, `version` can supply
`major`, `minor`, `patch` (default `0`), and optional `file` and `product` strings.
`file` defaults to `major.minor.patch.0`, and `product` defaults to `file`.
Version environment variables supplied by `xbuild.bat` take precedence.
VS Code can run `xmake check` without `INCLUDE`; xmake discovers MSVC during
configuration. Run `xmake f -c -m release -a x64` once if its toolchain cache is stale.

Run `xmake f -c -m release -a x64` after changing dependency paths, then build in
the existing Visual Studio Developer Command Prompt workflow (`xbuild.bat`).
The MSBuild workflow continues to use its separate ignored `env.bat` and
`weasel.props` files.

### Install and try it live

```batch
cd output
install.bat
```

### Optional: play with Rime command line tools

`librime` comes with a REPL application which can be used to test if the library
is working.

```batch
cd librime
copy /Y build\lib\Release\rime.dll build\bin
cd build\bin
echo zhongzhouyunshurufa | Release\rime_api_console.exe > output.txt
```

Instead of redirecting output to a file, you can set appropriate code page
(`chcp 65001`) and font in the console to work with the REPL interactively.
