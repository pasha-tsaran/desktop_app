# PDF viewer notices

The app pins pdfrx 2.6.1, with pdfium_dart 0.3.0 through pubspec.lock.
The package's native build hook bundles PDFium chromium/7811 for Windows x64.
The PDF viewer reads only the application's fixed offline policy asset.

Upstream archive used for these redistribution notices:
https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-win-x64.tgz

Archive SHA-256: 2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0

LICENSE and licenses/ are copied verbatim from that archive. Wrapper licenses
are copied from the pinned pdfrx and pdfium_dart packages. The release builder
includes this directory under the installed licenses/pdfium directory.
