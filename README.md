# HP M452nw Open Print

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#install)
[![Apple Silicon and Intel](https://img.shields.io/badge/architecture-Apple%20Silicon%20%7C%20Intel-blue)](#build-from-source)
[![Swift and C](https://img.shields.io/badge/Swift%20%2F%20C-native-F05138?logo=swift&logoColor=white)](Sources)

Native macOS printing for the **HP Color LaserJet M452nw**, with color and
manual two-sided printing in the normal **File → Print** dialog. Supports
multiple printers, A4/US Letter and collated copies.

## Install

Requires **macOS 13+** and a printer on the same local network. Download the
packages from [Releases](https://github.com/luborepka/hp-m452nw-driver/releases).

> [!IMPORTANT]
> The installer is **not signed or notarized yet**. macOS may show an
> **“unidentified developer” warning** or block it on first open. If you trust
> the download, you may need to approve it in **System Settings → Privacy &
> Security → Open Anyway**.

1. Open the **install.pkg** for your Mac: Apple Silicon (`arm64`) or Intel (`x86_64`).
2. Allow **Local Network** access, select your printer and click **Add or Update Printer**.
3. Choose your printer's **(Open Print)** queue in any application's Print dialog.

Reopen the installer to add another printer or update an existing one.
Prebuilt packages need no Python, Homebrew or developer tools.

## Print on both sides

The M452nw requires manual paper reloading:

1. **Empty front Tray 1** and leave plain paper in Tray 2.
2. Select **Two-Sided**, usually long-edge binding for a book. Some apps place
   this under **Printer Features → Two-Sided Printing (Manual Reload)**.
3. Wait until the fronts finish and the printer requests **Tray 1**.
4. Reload the whole output stack in the same order, **printed side DOWN,
   TOP EDGE first**. Press **OK** if asked.

Do not reload early. Jobs must fit Tray 1's **50-sheet capacity, including copies**.
Fit mixed portrait/landscape pages to one orientation in the original Print dialog.
Cancel jobs through Print Center; finish or cancel active jobs before updating.

## Uninstall

Remove a queue in **System Settings → Printers & Scanners → Remove Printer**.
For complete removal, open the matching **remove.pkg**. It removes all queues
managed by this driver, the background service, settings and saved job files.
Other printers are left alone.

## Build from source

Requires Apple's Command Line Tools. Running the integration tests also needs Python 3.

```sh
bash scripts/build.sh
build/hp-open-print-tests --self-test
python3 -m unittest discover -s Tests -v
bash scripts/package.sh
```

Packages and SHA-256 checksums are written to `build/release/`. Set `ARCH=arm64`
or `ARCH=x86_64` to cross-compile. Tests and developer tools are excluded from
packages. Publishing a GitHub release builds and tests both architectures, then
attaches the installer packages and checksums. A manual validation run is also available.

## How it works

One native Swift/C background process serves separate queues and job histories
for each printer, using macOS PDFKit and libcups. It prepares front/back PDF
passes and selects Tray 1 for the reload prompt.

Saved PDFs are private to your account under
`~/Library/Application Support/HP Open Print/Jobs/` and deleted after successful
printing. Unfinished jobs remain for recovery.

[MIT licensed](LICENSE). Independent project; HP and LaserJet are trademarks of HP.
