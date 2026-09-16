# FFmpeg, as used by Miau TV

Miau TV plays video through FFmpeg, which is licensed under the GNU Lesser General Public
License. This archive is the corresponding source for the FFmpeg binary shipped inside the app,
together with everything needed to rebuild it.

Nothing here is Miau TV's own source. FFmpeg is the only library in the app that asks for this.

## What is in here

| | |
|---|---|
| `ffmpeg-n6.1/` | The complete FFmpeg source the shipped binary was built from, with both patches below already applied. |
| `patches/` | The two changes made to upstream, so the difference is visible rather than buried in the tree. |
| `build-ffmpeg.sh` | The script that produced the binary: the exact configure flags, the platforms, and how the frameworks are assembled. |
| `COPYING.LGPLv2.1` | The licence the shipped build is under. |
| `LICENSE.md` | FFmpeg's own summary of which parts carry which terms. |

Upstream is FFmpeg at tag `n6.1`, from <https://git.ffmpeg.org/ffmpeg.git>. Applying the two
patches in `patches/` to a clean checkout of that tag reproduces `ffmpeg-n6.1/` exactly.

## The patches

**`0001-securetransport-no-SecItemImport-on-catalyst.patch`** stops `import_pem` using
`SecItemImport`, which is macOS only. Mac Catalyst cross compiles against the macOS SDK, so
configure's link check finds it, but the `ios-macabi` target marks it unavailable and the build
fails. Only client certificate loading uses it, which nothing in the app asks for.

**`0002-videotoolbox-metal-compatibility.patch`** asks CoreVideo for Metal compatible pixel
buffers rather than OpenGL ES ones. This comes from the FFmpegKit build tooling rather than from
Miau TV, and is included because it is in the shipped binary.

## How the shipped build was made

`build-ffmpeg.sh` drives [FFmpegKit](https://github.com/kingslay/FFmpegKit) at tag `6.1.4`, which
fetches FFmpeg and runs the configure and make for each Apple platform. Two things about it are
deliberate and are what make this archive the whole story rather than half of it:

- **It is built without the GPL.** FFmpeg is LGPL by default and only becomes GPL if asked, which
  the stock FFmpegKit release does. The script passes `disableGPL` and refuses to package anything
  whose generated `config.h` does not say `CONFIG_GPL 0`.
- **`--enable-version3` is removed**, so the build is LGPL 2.1 rather than LGPL 3. The script
  checks the artefact for that too, and stops if it disagrees.

The resulting libraries are linked into a single dynamic `FFmpeg.framework` rather than static
archives, and the app links against it dynamically. That is what lets anyone holding a copy of
Miau TV replace this library with a build of their own: swap the framework inside the app bundle
and re-sign it.

To rebuild, you need `autoconf automake nasm yasm meson gnu-sed` and Xcode, then run
`build-ffmpeg.sh`. It takes a few hours for all five platforms.
