# Purchase Information Sync

[![Buy me a coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=russcollis&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff)](https://www.buymeacoffee.com/russcollis)

A macOS app that pulls device purchase and warranty information from **Apple Business Manager (ABM)** or **Apple School Manager (ASM)** and writes Jamf-ready CSV files:

| Output | Format | Use |
| --- | --- | --- |
| `ComputerTemplate.csv` | MUT Computer Template | Bulk-update Macs with The MUT |
| `MobileDeviceTemplate.csv` | MUT Mobile Device Template | Only written when mobile devices are included |
| `inventory-preload-template.csv` | Jamf Pro Inventory Preload | Upload in **Settings › Inventory Preload** |

It is a native replacement for the `warranty_wrangler` zsh script (v2.0.0). The app uses the same API calls, the same coverage logic and the same vendor lookup, and it needs no `jq`, `openssl` or `curl`.

---

## Requirements

- macOS 27.2 or later
- An ABM/ASM **API account**. In ABM go to **Preferences › API** and create a key. This gives you:
  - **Client ID**, for example `BUSINESSAPI.xxxxxxxx-xxxx-…`
  - **Key ID**, for example `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
  - **Private key** `.pem` file (P-256 EC key)

---

## Setup

1. Launch **Purchase Information Sync**.
2. Under **Apple Business Manager API**:
   - Choose **Apple Business Manager** or **Apple School Manager**.
   - Paste the **Client ID** and **Key ID**.
   - Click **Choose…** next to **Private Key (.pem)** and select the key file.
3. Under **Output**:
   - Choose the **Output Folder**.
   - Adjust the file names if needed.
   - Pick **Devices**: *Mac only*, *Mobile only* or *Mac + Mobile*.
   - Optionally enter **Product Families**, comma-separated, for example `Mac, iPad`.
4. Click **Test Connection**. When it succeeds, the **Key ID is masked** (`••••••••••••-abcd`) and marked as verified.
5. Click **Sync Purchase Information**.

All settings are **saved automatically** and restored at the next launch. **Clear Saved Settings…** removes them.

### Key ID masking

- The Key ID is shown in full until a token request succeeds, either from **Test Connection** or at the start of a sync.
- After that it is masked, showing only the last 4 characters.
- Click **Change** to reveal and edit it. Editing the value clears the verified state until it is tested again.

---

## Vendors

ABM identifies the reseller of each device by a **purchase source ID**. The vendor table maps those IDs to readable names, which are written as `Name (ID)`, for example `Jigsaw24 (2287450)`.

Default entries:

| Purchase Source ID | Vendor |
| --- | --- |
| `1C99B860` | O2 UK |
| `2287450` | Jigsaw24 |
| `A3F0E30` | Viewdata Computing Ltd |
| `892F050` | COMPUTACENTER (UK) LTD |
| `1D0CDC710` | Vohkus Ltd |

- **Add Vendor** / **Remove** to edit the list; **Restore Defaults** resets it.
- IDs are **case-sensitive** and must match ABM exactly.
- Unknown IDs are looked up through the ABM `purchaseSources` API. The log shows the resolved name so you can add it to the table.
- Devices with no purchase source ID (for example `MANUALLY_ADDED`) show the purchase source type instead.

---

## Output details

### Field mapping

| ABM / ASM data | Computer / Mobile Template | Inventory Preload |
| --- | --- | --- |
| Serial number | Computer Serial / Mobile Device Serial | Serial Number |
| Product family | — | Device Type (`Computer` / `Mobile Device`) |
| `orderNumber` | PO Number | PO Number |
| `orderDateTime` (date only) | PO Date | PO Date |
| Purchase source | Vendor | Purchasing Contact |
| Coverage end date | Warranty Expires | Warranty Expiration |
| AppleCare `agreementNumber` | AppleCare ID | Apple Care ID |

### Warranty logic

- **Warranty Expires** uses the end date of an **active AppleCare** plan. If there isn't one, it uses the **Limited Warranty** end date.
- **AppleCare ID** is the agreement number of the active AppleCare plan. If no plan is active, the first AppleCare plan returned by ABM is used.
- If coverage can't be retrieved for a device, its row is still written with the PO fields, and it is counted under **Coverage errors**.

### Existing data is always read first

Before downloading anything, the app reads the Computer Template (or Mobile Device Template) and the Inventory Preload file already in the output folder:

| Device is… | Result |
| --- | --- |
| In **both** files | Skipped. No API calls. |
| In **one** file only | The missing row is **copied from the existing row**. No coverage call. |
| In **neither** file | Coverage is downloaded from ABM and appended to both files. |

- The device list itself still has to be paged from ABM each run so that new devices can be found. The per-device coverage lookups, which take most of the time, only happen for new devices.
- A preload row only counts as a copy source if it contains purchase data (PO number, PO date, warranty or AppleCare ID). Rows with just a vendor, like the older preload files, still trigger a coverage download for the template.
- Existing files must have the **expected column headers**. If a file's columns differ, the sync stops rather than appending misaligned rows.
- To start completely fresh, move or rename the existing files, or set new file names.

Rows are written as each device is processed, so a cancelled or interrupted run keeps everything written up to that point.

---

## Reliability

- **429 Too Many Requests:** honours `Retry-After`, otherwise retries with exponential backoff plus jitter, up to 10 attempts.
- **401 Unauthorized:** requests a new token and retries.
- **Network or invalid responses:** retried with backoff.
- **Pacing:** 0.1 s between devices and 0.3 s between pages, as in the script.
- **Sleep prevention:** the Mac is kept awake while a sync runs (the equivalent of `caffeinate`).

---

## Troubleshooting

| Message | Cause / Fix |
| --- | --- |
| *The .pem file could not be read as an EC (P-256) private key* | The file isn't a P-256 private key. ABM keys labelled `EC PRIVATE KEY` that contain PKCS#8 data are supported. |
| *Token request failed (HTTP 400/401)* | Check the Client ID and Key ID, that the `.pem` matches that key, and that the right service (ABM vs ASM) is selected. |
| *Could not prepare output files* | Choose the output folder again, so the app has write access to it. |
| Asked to choose the .pem or folder again after relaunch | The saved file access has expired (for example, the file was moved). Select it again. |

---

## Building

Use `build.sh` in the repository root. It builds Release and writes the output to `dist/`. Both `build/` and `dist/` are git-ignored.

```zsh
./build.sh                 # ad-hoc signed .app + .zip (this Mac / internal testing)
./build.sh --dmg           # also create a .dmg
./build.sh --clean         # remove previous build output first
./build.sh --version 1.1   # set the marketing version (build number defaults to the git commit count)
```

### Distribution (Developer ID + notarization)

Store the notarization credentials once:

```zsh
xcrun notarytool store-credentials NotaryProfile --apple-id you@example.com --team-id ABCDE12345
```

Then build, sign and notarize:

```zsh
./build.sh --sign "Developer ID Application" --team ABCDE12345 --notarize NotaryProfile --dmg
```

| Option | Description |
| --- | --- |
| `--sign IDENTITY` | Code signing identity (default: ad-hoc). Requires `--team`. Enables Hardened Runtime. |
| `--team TEAM_ID` | Apple Developer Team ID |
| `--bundle-id ID` | Override the bundle identifier. Saved settings are tied to the bundle ID, so changing it starts with fresh settings. |
| `--version X.Y.Z` | Marketing version |
| `--build-number N` | Build number |
| `--notarize PROFILE` | Notarize and staple with a `notarytool` keychain profile |
| `--dmg` | Also produce a `.dmg`. A DMG failure only produces a warning; the `.app` and `.zip` are still created. |
| `--clean` | Delete `build/` and `dist/` first |

Ad-hoc builds run on the Mac that built them, but Gatekeeper blocks them on other Macs. Use Developer ID signing and notarization to distribute the app.

---

## Project structure

| File | Purpose |
| --- | --- |
| `Warranty Preload/MyApp.swift` | App entry point |
| `Warranty Preload/ContentView.swift` | User interface (settings, vendor table, activity log) |
| `Warranty Preload/SettingsStore.swift` | Saved settings, vendor list, file access |
| `Warranty Preload/ABMClient.swift` | JWT signing (CryptoKit ES256), OAuth token, API calls with retry/backoff |
| `Warranty Preload/SyncEngine.swift` | Sync process, coverage logic, CSV writing |

The app is sandboxed. It is allowed outgoing network connections and read/write access to files and folders you select.

---

## Credits

Based on **Warranty Wrangler**, by Brandon Woods with contributions from the Jamf Nation community (fpatafta, MultiSiggloo) and Russell Collis.
