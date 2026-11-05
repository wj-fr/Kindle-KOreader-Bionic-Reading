**English** | [简体中文](README.zh-CN.md)

# A self-use ADHD bionic reading plugin, made purely with AI

# Kindle-KOreader-Bionic-Reading (Bionic Reading Plugin)

A bionic reading plugin for EPUB books in [KOReader](https://koreader.rocks/). It bolds the first part of each word to guide your eyes across the text and make reading feel lighter. It supports English and Chinese, is designed for e-ink devices such as jailbroken Kindles, and works with [月读 (Moon)](https://github.com/AnkioTomas/moon).

<!-- Suggestion: add 2-3 screenshots here: the settings menu, and a before/after comparison -->

## Features

- **One-tap switch**: turn bionic reading on or off per EPUB book, or make it the default for all EPUB books. You can also bind "Bionic reading: toggle" to a gesture in KOReader's gesture manager.
- **Your books are never modified**: the original file stays untouched. The plugin stores the converted content as a cached copy, and KOReader still believes you are reading the original book, so the title, reading progress and reading history stay the same.
- **Separate settings for English and Chinese**: English is emphasised word by word; Chinese has no spaces, so text is split into groups of a fixed number of characters. The two sets of settings are independent.
- **Plenty of appearance options**: emphasis strength, word skipping, stem length, edge brightness, 6 emphasis styles and 6 colours (for colour screens).
- **Presets**: save several sets of settings for English and for Chinese and apply them with one tap.
- **Notes stay in place**: highlights and notes made under bionic reading are stored separately for each rendering, so they do not shift when you switch settings.
- **Backup and restore**: back up the highlights and notes of all your books at any time, with a custom backup name. Restoring only adds back what is missing.
- **Export bionic EPUB**: export the converted book as a standalone EPUB to read on other devices.
- **月读 (Moon) compatible**: if Moon is installed, a "Bionic reading" button is added to Moon's reading panel, and chapters from Moon's online sources are supported. The plugin works fine without Moon.
- **Chinese and English interface**: switch the menu language at any time. By default it follows KOReader's interface language.

## Compatibility

| Item | Notes |
|---|---|
| Verified device | Kindle 2024 (firmware 5.18, jailbroken, KOReader installed) |
| Other devices | The plugin contains no device-specific code, so it should work on any device that runs KOReader, but it is **untested** |
| Supported format | EPUB only. PDF, MOBI, AZW3 and other formats are not supported; convert them to EPUB first with a tool such as Calibre |
| Dependencies | No other plugins required. Moon is optional |

This is an independent third-party project and is not affiliated with the KOReader or Moon projects.

<!-- Suggestion: add the KOReader version you tested with -->

## Installation

1. On this repository's **Releases** page, download the latest `bionic.koplugin-vX.Y.Z.zip`. Download the file uploaded in the Release, **not** the automatically generated "Source code" archives.
2. Unzip it to get the `bionic.koplugin` folder. **Do not rename the folder.**
3. Connect the Kindle with a USB cable and copy the whole `bionic.koplugin` folder into KOReader's `plugins` directory. On a Kindle this is usually `/mnt/us/koreader/plugins/`.
4. Eject the device and restart KOReader (or exit KOReader and open it again).
5. Open any EPUB and find "Bionic reading" in the top menu.

## Quick start

**Where to find the menu** (may differ slightly between KOReader versions):

- While reading: top menu → Typesetting tab → Bionic reading
- In the file browser: top menu → More tools → Bionic reading

**Getting started:**

1. Open an EPUB and tick "Bionic reading for this book". The first time, the whole book has to be converted, which can take a while for large books on older devices; afterwards the cache is used directly.
2. To turn it on for every EPUB by default, tick "Always on for EPUB books".
3. Adjust the effect under "English / Latin text" and "Chinese (Han characters)". Changes are applied to the book you are reading immediately.
4. For a quick on/off, bind "Bionic reading: toggle" to a gesture in KOReader's gesture manager.

## Settings

### English / Latin text

English, Greek, Cyrillic and other scripts that separate words with spaces are all handled by these settings.

| Setting | Range | Default | Description |
|---|---|---|---|
| Bionic effect on English text | On / Off | On | When off, nothing is applied |
| Fixation strength | 1 – 4 | 2 | How much of each word is emphasised. 1 is the least, 4 is the whole word stem |
| Saccades interval | 0 – 4 | 0 | How many words to skip between two emphasised words. 0 means every word is emphasised |
| Word stem length | 30 – 100% | 70% | The share of a longer word that can be emphasised |
| Edge opacity | 20 – 100% | 100% | Brightness of the un-emphasised part of a word. 100 means no dimming. **Keep it at 100 on e-ink screens** |
| Emphasis style | 6 styles | Bold | Bold, semi-bold, extra-bold, underline, bold + underline, italic. Whether semi-bold and extra-bold work depends on whether the font has those weights |
| Emphasis colour | On / Off | Off | Only works on colour screens |
| Colour | 6 colours | Red | Red, blue, green, orange, purple, brown. The colours are darkened to suit colour e-ink screens |

### Chinese (Han characters)

Chinese has no spaces, so words cannot be recognised. The plugin therefore splits the text into **groups of N characters** and emphasises the first part of each group. This is a fixed-length approximation, not real word segmentation.

| Setting | Range | Default | Description |
|---|---|---|---|
| Bionic effect on Chinese text (chunk size) | 0 – 6 | 0 (off) | N characters per group. 0 means Chinese is not processed. This also applies to Japanese kana and Korean |
| Emphasised share | 20 – 80% | 50% | The share of each group that is emphasised. 50% means the first half |
| Saccades interval | 0 – 4 | 0 | How many groups to skip between two emphasised groups |
| Edge opacity | 20 – 100% | 100% | Brightness of the un-emphasised part of each group |
| Emphasis style, emphasis colour, colour | Same as English | Same as English | Set separately from English |

### General options

- **Page theme for dimming**: light page (dark text) or dark page (light text). It only matters when edge opacity is below 100%.
- **Separate settings for this book**: when ticked, this book uses its own set of settings and does not affect other books. Untick it to go back to the global settings.
- **Clear conversion cache**: deletes the cached converted copies to free up space. They are converted again the next time a book is opened.
- **Language / 语言**: at the very bottom of the menu; switches between the Chinese and English interface.

## Presets

At the bottom of both the "English / Latin text" and "Chinese (Han characters)" pages there is a "Presets" entry.

- **Save current settings as preset…**: give the current settings a name and save them. If you leave the name empty, it is named "Preset 1", "Preset 2" and so on automatically. Using an existing name updates that preset.
- **Default settings**: a built-in entry that restores the plugin's defaults.
- **Tap a preset name**: applies that preset. When the current settings exactly match a preset, it shows a tick.
- **Delete preset**: choose a preset to delete.

English and Chinese presets are independent. **Presets do not change the on/off switch of the bionic effect**: whether the English effect and the Chinese effect are on is up to you; switch them manually, then pick a preset. The Chinese "chunk size" is also the on/off switch of the Chinese effect, so applying a preset only changes it when the Chinese effect is already on.

## Highlights, notes, backup and restore

### How notes are stored

In an EPUB, the position of a highlight is recorded in the document structure, and the bionic effect changes that structure. To keep highlights from shifting when you switch, the plugin gives **each text structure its own separate set of highlights and notes**:

- Turning the bionic effect on or off, and changing emphasis strength, saccades interval, word stem length, emphasis style, whether the edge is dimmed, or the Chinese grouping parameters, switches to a different set.
- Changing only the colour, the exact edge opacity value, or the page theme does not switch sets.
- Your other sets of notes are not lost; they are just hidden for now and reappear when you switch back to the matching settings.

> Highlights made under a bionic rendering cannot be moved into the original text, so notes on the original text and notes under the bionic effect are kept apart.

### Backup

Menu: Bionic reading → Backup highlights and notes

- **Back up now…**: opens a naming dialog. Enter a name, or leave it empty to use the date and time as the name.
- **Delete backups**: lists all backups; tap one and confirm to delete it. You can also delete all backups at once.
- Scope: books in your reading history, books the plugin has processed, and the book currently open. Chapters from Moon's online sources and the conversion cache are not included.
- Each backup is stored in `koreader/bionic_backups/<date-time>/` and contains three files:
  - `backup.lua`: the complete data, used for restoring
  - `backup.txt`: highlights and notes as human-readable text
  - `info.lua`: brief information such as the name and time

### Restore

Menu: Bionic reading → Restore backup

- **Only possible from the file browser** (with no book open). An open book writes the highlights in memory back to disk when it is closed, which would overwrite the restored content.
- Restoring only **adds back highlights and notes that are missing** from a book. It **never deletes or changes** existing content, so restoring repeatedly does not create duplicates.
- Highlights go back to the set they originally belonged to, so they do not shift.
- Books that can no longer be found are skipped and mentioned in the result.

Two small limitations:

- If you deliberately deleted a highlight after the backup was made, restoring will add it back.
- Restored highlights are inserted by document position, but when a paragraph contains headings, images and the like, the order may be slightly off. This only affects the order of "next highlight" navigation; no data is lost.

## Export bionic EPUB

Menu: Bionic reading → Export → Export bionic EPUB

Exports the converted book as a standalone EPUB file that you can read on other devices.

- You can choose whether to add "(Bionic)" after the book title in the exported file, so it does not share a name with the original.
- By default the file is exported to `documents/bionic_export`; you can change the export folder.
- Only regular EPUB books are supported, not chapters from Moon's online sources.

## Working with 月读 (Moon)

- Without Moon: the plugin works normally, and Moon-related files and menu items have no effect.
- With Moon: a "Bionic reading" button is added to the reading panel, and you can set "Always on for online-source chapters".
- Chapters from Moon's online sources are **rewritten in place** (the original is backed up as `.html.bionic`). The plugin restores them automatically when uninstalled; you can also restore them at any time with "Restore original online-source chapters".
- Moon is still evolving quickly. If the button disappears from the panel after a Moon upgrade, or online chapters stop working, please open an Issue.

## Where data is stored

All paths below are under KOReader's data directory (usually `/mnt/us/koreader/` on a Kindle):

| Path | Contents |
|---|---|
| `settings/bionic_reading.lua` | The plugin's settings and presets |
| `bionic_cache/` | Converted cached copies; can be cleared at any time |
| `bionic_backups/` | Manual backups |
| `bionic_save/` | Created only on uninstall; holds the kept notes text and backup |
| `../documents/bionic_export/` | Default export location |

## Updating

Menu → Bionic reading → **Check for updates** (requires a network connection). Restart KOReader after updating; the previous version is kept as `plugins/bionic.koplugin.old` so you can roll back by hand.

## Uninstalling

In the **file browser** (not inside a book): Bionic reading → Uninstall Bionic Reading…. Three options appear:

- **Cancel**: does nothing.
- **Uninstall**: books return to their original text, and notes made under the bionic effect are saved as a text file in `koreader/bionic_save`. The plugin, cache, settings and all manual backups are deleted.
- **Uninstall and keep backup**: as above, and additionally keeps the latest backup, also in `koreader/bionic_save`. If you want to use the plugin again later, copy the backup folder from there back into `koreader/bionic_backups/`.

The `bionic_save` folder is created only on uninstall, and only when there is actually something to save.

## FAQ

**I can't see any bold effect?**
Some fonts have no bold weight. Switch to a font that has a bold weight, or change the emphasis style to "underline". Whether "semi-bold" and "extra-bold" work depends on whether the font has those weights.

**"Bionic reading for this book" is greyed out in the menu?**
The book currently open is not an EPUB. This plugin only supports EPUB.

**The first time is slow?**
The first time, the whole book has to be converted; afterwards the cache is used directly. Large books are slower on older devices.

**My reading position shifted a little after changing settings?**
Settings that change the text structure trigger a new conversion, and the plugin returns to your position by percentage, so there may be a slight offset.

**My highlights have disappeared?**
Highlights are stored in separate sets by text structure (see above). Change the settings back to what they were when you made the highlights and they will reappear. You can also bring them back from "Restore backup".

**The cache takes up too much space?**
"Clear conversion cache" in the menu shows the size it uses; tap it to clear.

**The Chinese effect looks strange?**
Chinese is grouped by a fixed number of characters rather than by real word segmentation, so the emphasised part does not necessarily fall on word boundaries. Try different chunk sizes and emphasised shares.

## Known limitations

- EPUB only.
- Chinese uses fixed-length grouping, not word segmentation.
- Verified only on Kindle 2024 (firmware 5.18).
- The plugin uses some of KOReader's internal interfaces, so it may need adapting after a major KOReader update. After upgrading KOReader, back up your highlights and notes first, then try it on a book you do not care about.
- Moon's interfaces are evolving quickly, so Moon-related features may need adapting after a Moon upgrade.

## Feedback

Please report problems in Issues. To help locate them, include as much of the following as you can:

- Device model and firmware version
- KOReader version
- Plugin version (the version number in the downloaded zip file name)
- Steps to reproduce
- If there is a crash, the `crash.log` from KOReader's data directory

## Credits & License

- [JiffyReader](https://github.com/jiffyreader/jiffyreader-plugin) (GPL-3.0)
- [KOReader](https://github.com/koreader/koreader), [月读 Moon](https://github.com/AnkioTomas/moon)
- This project is released under GPL-3.0; see `LICENSE`.
