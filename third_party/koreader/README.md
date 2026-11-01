# KOReader for Android (third-party)

The release offers to install this exact KOReader build when it is missing, because it
is the build everything in this repository is tested with:

- File: `koreader-android-arm-v2026.07.2-217-gb44e9b7.apk` (32-bit ARM, `armeabi-v7a`)
- Version: `v2026.07.2-217-gb44e9b7_2026-10-03` (nightly), package `org.koreader.launcher`
- SHA-256: `e76aa277aaf2dfca13f1e0b28d43bd68b4dafd4978586506b22aa3762863b464`
- Signed by KOReader's nightly certificate (`CN=Android Debug`, SHA-256
  `1e08a903aef9c3a721510b64ec764d01d3d094eb954161b62544ea8f187b5953`)

KOReader's server keeps only recent nightlies, and this one is no longer offered there, so
the APK was copied from a Nook running it (`make pull-koreader`). The APK itself is not
committed to git; `make dist` checks it against the SHA-256 above and adds it to the release.

## License and source

KOReader is free software under the GNU Affero General Public License v3.0, by the KOReader
developers. Its source code for this build is KOReader commit `b44e9b7`:
<https://github.com/koreader/koreader/tree/b44e9b7>, which pins the Android launcher
(<https://github.com/koreader/android-luajit-launcher>) as a submodule.
