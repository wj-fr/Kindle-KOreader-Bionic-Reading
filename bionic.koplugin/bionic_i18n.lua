-- Tiny UI translation layer: English msgid -> Simplified Chinese.
-- Strings are looked up lazily, so switching language takes effect immediately.
local I18n = { lang = "en" }

local ZH = {
    ["Bionic reading"] = "仿生阅读",
    ["Bionic reading for this book"] = "本书启用仿生阅读",
    ["Always on for EPUB books"] = "所有 EPUB 书籍默认开启",
    ["Always on for online-source chapters"] = "月读在线书源章节默认开启",
    ["Fixation strength: %1"] = "加粗强度：%1",
    ["Fixation strength"] = "加粗强度",
    ["How much of each word is emphasised (1 = least, 4 = whole word stem)."] =
        "每个词加粗多少（1 最少，4 为整个词干）。",
    ["Saccades interval: %1"] = "跳词间隔：%1",
    ["Saccades interval"] = "跳词间隔",
    ["Words left un-emphasised between emphasised words. 0 = every word."] =
        "两个加粗词之间跳过的词数。0 表示每个词都加粗。",
    ["Word stem length: %1%"] = "词干长度：%1%",
    ["Word stem length (%)"] = "词干长度（%）",
    ["Share of a longer word that can be emphasised. Default is 70."] =
        "较长单词中可被加粗部分的占比。默认值为 70。",
    ["Edge opacity: %1%"] = "词尾亮度：%1%",
    ["Edge opacity (%)"] = "词尾亮度（%）",
    ["Brightness of the un-emphasised part of words. 100 = unchanged (best for e-ink)."] =
        "未加粗部分的亮度。100 表示不变暗（最适合墨水屏）。",
    ["Emphasis style: %1"] = "强调样式：%1",
    ["bold"] = "加粗",
    ["underline"] = "下划线",
    ["Bionic effect on Chinese text: %1"] = "对中文文字使用仿生效果：%1",
    ["Chunk size"] = "分组大小",
    ["off"] = "关闭",
    ["Chinese/Japanese/Korean have no spaces, so words cannot be detected. If set to N, every N characters are treated as one 'word'. 0 = leave CJK text alone."] =
        "中日韩文字没有空格，无法识别词语。设为 N 时，每 N 个字视为一个“词”。0 表示不处理中日韩文字。",
    ["Restore original online-source chapters"] = "还原月读在线书源章节为原文（卸载前使用）",
    ["Restored %1 chapter files."] = "已还原 %1 个章节文件。",
    ["Uninstall Bionic Reading…"] = "卸载仿生阅读…（请在文件浏览器中使用）",
    ["Uninstall"] = "卸载",
    ["Bionic Reading has been uninstalled. Restart KOReader now?"] = "仿生阅读已卸载。现在重启 KOReader 吗？",
    ["Almost done. Please delete this folder by hand: %1. Restart KOReader now?"] = "基本完成。请手动删除这个文件夹：%1。现在重启 KOReader 吗？",
    ["Restart"] = "重启",
    ["Later"] = "稍后",
    ["Clear conversion cache (%1 files, %2)"] = "清除转换缓存（%1 个文件，%2）",
    ["Applying bionic reading…"] = "正在应用仿生阅读…",
    ["Conversion failed."] = "转换失败。",
    ["The original book file could not be found."] = "找不到原书文件。",
    ["Bionic reading works on EPUB books only."] = "仿生阅读仅支持 EPUB 书籍。",
    ["Bionic reading: toggle"] = "仿生阅读：开关",
    ["Cannot open the EPUB file."] = "无法打开 EPUB 文件。",
    ["Cannot create the converted file."] = "无法创建转换后的文件。",
    ["This book appears to be DRM-protected; it cannot be converted."] = "这本书似乎有 DRM 保护，无法转换。",
    ["Failed to read a file inside the EPUB."] = "读取 EPUB 内部文件失败。",
    ["Failed to write the converted file."] = "写入转换后的文件失败。",
    ["No convertible text was found in this EPUB."] = "这本 EPUB 中没有可转换的文字。",
    ["Cannot save the converted file."] = "无法保存转换后的文件。",
    ["Separate settings for this book"] = "本书使用独立设置",
    ["Emphasis colour (colour screens)"] = "强调颜色（彩色屏幕）",
    ["Colour: %1"] = "颜色：%1",
    ["Bold"] = "加粗",
    ["Semi-bold (font dependent)"] = "半粗（取决于字体）",
    ["Extra bold (font dependent)"] = "特粗（取决于字体）",
    ["Underline"] = "下划线",
    ["Bold + underline"] = "加粗 + 下划线",
    ["Italic"] = "斜体",
    ["Red"] = "红色",
    ["Blue"] = "蓝色",
    ["Green"] = "绿色",
    ["Orange"] = "橙色",
    ["Purple"] = "紫色",
    ["Brown"] = "棕色",
    ["Export"] = "导出",
    ["Export bionic EPUB"] = "导出仿生 EPUB",
    ["Add \"(Bionic)\" to the book title in the exported file"] = "在导出文件的书名后加上“(Bionic)”",
    ["Export folder: %1"] = "导出文件夹：%1",
    ["Export folder"] = "导出文件夹",
    ["Folder for exported EPUB files"] = "存放导出 EPUB 的文件夹",
    ["Default"] = "默认",
    ["Only EPUB books can be exported."] = "只能导出 EPUB 格式的书。",
    ["Preparing the bionic EPUB…"] = "正在准备仿生 EPUB…",
    ["Cannot create the export folder: %1"] = "无法创建导出文件夹：%1",
    ["Export failed: %1"] = "导出失败：%1",
    ["Exported to: %1"] = "已导出到：%1",
    ["Cancel"] = "取消",
    ["Save"] = "保存",
    ["Bionic effect on English text"] = "对英文文字启用仿生效果",
    ["Your highlights and notes from bionic renderings were saved to: %1"] = "在仿生渲染中做的高亮和笔记已保存到：%1",
    ["Could not save your highlights and notes to %1. Nothing was uninstalled."] = "无法把你的高亮和笔记保存到 %1，因此没有进行任何卸载。",
    ["English / Latin text"] = "英文（拉丁字母）",
    ["Chinese (Han characters)"] = "中文（汉字）",
    ["Emphasised share: %1%"] = "强调比例：%1%",
    ["Emphasised share (%)"] = "强调比例（%）",
    ["Share of each chunk that is emphasised. 50 = the first half."] = "每个分组中被强调的比例。50 表示前一半。",
    ["Chunks left un-emphasised between emphasised chunks. 0 = every chunk."] = "两个被强调的分组之间跳过的分组数。0 表示每个分组都强调。",
    ["Brightness of the un-emphasised part of each chunk. 100 = unchanged."] = "每个分组中未强调部分的亮度。100 表示不变。",
    ["Page theme for dimming: %1"] = "变暗参照的页面主题：%1",
    ["Light page (dark text)"] = "浅色页面（深色文字）",
    ["Dark page (light text)"] = "深色页面（浅色文字）",
    ["%1 highlights/notes belong to a different bionic rendering of this book. They are kept and will come back when you switch back."] =
        "本书有 %1 条高亮/笔记属于另一种仿生渲染方式。它们已妥善保存，切换回去后会重新出现。",
    -- backups of highlights and notes
    ["Backup highlights and notes"] = "备份高亮和笔记",
    ["Back up now…"] = "立即备份…",
    ["Name this backup"] = "为本次备份命名",
    ["Backup name (empty = %1)"] = "备份名称（留空则为 %1）",
    ["Back up"] = "备份",
    ["Backing up…"] = "正在备份…",
    ["Nothing to back up: no highlights or notes were found."] = "没有可备份的内容：没有找到任何高亮或笔记。",
    ["Backed up %1 highlights/notes from %2 books as \"%3\".\nSaved in: %4"] =
        "已备份 %2 本书的 %1 条高亮/笔记，名称：\"%3\"。\n保存位置：%4",
    ["Backup failed: %1"] = "备份失败：%1",
    ["Delete backups (%1)"] = "删除备份（%1）",
    ["No backups yet"] = "还没有备份",
    ["%1 (%2 books, %3 notes)"] = "%1（%2 本书，%3 条）",
    ["Delete backup \"%1\"?\n%2 books, %3 highlights/notes, made %4."] =
        "删除备份 \"%1\"？\n%2 本书，%3 条高亮/笔记，创建于 %4。",
    ["Delete"] = "删除",
    ["Backup deleted."] = "备份已删除。",
    ["Could not delete the backup."] = "无法删除该备份。",
    ["Delete all backups"] = "删除全部备份",
    ["Delete all %1 backups? This cannot be undone."] = "删除全部 %1 个备份？此操作无法撤销。",
    ["Deleted %1 backups."] = "已删除 %1 个备份。",
    ["Backups folder: %1"] = "备份文件夹：%1",
    -- presets
    ["Presets (%1)"] = "预设（%1）",
    ["Save current settings as preset…"] = "将当前设置保存为预设…",
    ["Name this preset"] = "为预设命名",
    ["Preset name (empty = %1)"] = "预设名称（留空则为 %1）",
    ["Preset %1"] = "预设 %1",
    ["Preset saved: %1"] = "已保存预设：%1",
    ["Preset updated: %1"] = "已更新预设：%1",
    ["Default settings"] = "默认设置",
    ["Delete preset"] = "删除预设",
    ["Delete preset \"%1\"?"] = "删除预设 \"%1\"？",
    ["Preset deleted."] = "预设已删除。",
    ["No presets yet"] = "还没有预设",
    -- restoring a backup
    ["Restore backup (%1)"] = "还原备份（%1）",
    ["Restore backup: close the book first"] = "还原备份：请先关闭当前书籍",
    ["Restore \"%1\"?\nHighlights and notes that are missing from your books are added back (this backup has %2 books, %3 highlights/notes). Nothing already in your books is removed or changed."] =
        "还原 \"%1\"？\n你的书中缺少的高亮和笔记会被补回（此备份含 %2 本书、%3 条高亮/笔记）。书中已有的内容不会被删除或修改。",
    ["Restore"] = "还原",
    ["Restoring…"] = "正在还原…",
    ["Restored %1 highlights/notes in %2 books."] = "已补回 %2 本书中的 %1 条高亮/笔记。",
    ["Nothing to restore: everything in this backup is already in your books."] = "无需还原：此备份中的内容已全部在你的书中。",
    ["%1 books were not found and skipped."] = "有 %1 本书找不到，已跳过。",
    ["%1 books could not be written."] = "有 %1 本书写入失败。",
    ["Restore failed: %1"] = "还原失败：%1",
    -- uninstall
    ["If you uninstall Bionic Reading, your books go back to the original text. Highlights and notes made under the bionic effect may be lost, so they are saved to a text file by default. You can also keep the latest backup. The backup data and the text file are stored in koreader/bionic_save."] =
        "如果确定卸载仿生阅读，书籍会还原为原文。仿生效果下做的笔记有丢失可能，默认保存为一个文本文件，也可选择同时保留最新备份，备份数据与文本文件将存放在koreader/bionic_save。",
    ["Uninstall and keep backup"] = "卸载并保留备份",
    ["Before uninstall"] = "卸载前",
    ["The latest backup was kept in: %1"] = "最新备份已保留在：%1",
    ["There was no backup to keep (no highlights or notes were found)."] = "没有可保留的备份（没有找到任何高亮或笔记）。",
    ["Check for updates (current v%1)"] = "检查更新（当前 v%1）",
    ["Checking for updates…"] = "正在检查更新…",
    ["Could not check for updates: %1"] = "无法检查更新：%1",
    ["You already have the latest version (v%1)."] = "已是最新版本（v%1）。",
    ["New version %1 is available (you have v%2). Update now?"] = "发现新版本 %1（当前 v%2），现在更新吗？",
    ["Update"] = "更新",
    ["Downloading update…"] = "正在下载更新…",
    ["Updated to %1. Restart KOReader now to use the new version?"] = "已更新到 %1。现在重启 KOReader 以使用新版本吗？",
    ["Update failed: %1"] = "更新失败：%1",
    ["No release was found on GitHub."] = "GitHub 上还没有发布版本。",
    ["Unexpected reply from GitHub."] = "GitHub 返回了无法识别的内容。",
    ["This release has no downloadable file."] = "该版本没有可下载的文件。",
    ["The downloaded file is not a valid zip."] = "下载的文件不是有效的 zip。",
    ["Failed to read a file inside the zip."] = "读取 zip 内的文件失败。",
    ["The download does not look like this plugin."] = "下载的内容看起来不是本插件。",
    ["Cannot create a temporary folder."] = "无法创建临时文件夹。",
    ["Cannot write the new files."] = "无法写入新文件。",
    ["The download is missing %1."] = "下载内容缺少 %1。",
    ["The downloaded file %1 is broken."] = "下载的文件 %1 已损坏。",
    ["Cannot replace the plugin folder."] = "无法替换插件文件夹。",
    ["Cannot find the plugin folder."] = "找不到插件文件夹。",
    ["The update source is not configured yet (set REPO in bionic_update.lua)."] = "尚未配置更新源（请在 bionic_update.lua 中设置 REPO）。",
}

function I18n.setLang(lang)
    I18n.lang = (lang == "zh") and "zh" or "en"
end

-- guess a default from KOReader's own UI language ("zh_CN", "zh_TW", ... -> Chinese)
function I18n.detect()
    local ok, lang = pcall(function() return G_reader_settings and G_reader_settings:readSetting("language") end)
    if ok and type(lang) == "string" and lang:sub(1, 2):lower() == "zh" then return "zh" end
    return "en"
end

function I18n.tr(s)
    if I18n.lang == "zh" then return ZH[s] or s end
    return s
end

return I18n
