module postprocess;

import config : resolvePath;
import std.algorithm.sorting : sort;
import std.array : replace;
import std.datetime : SysTime;
import std.file : exists, readText, timeLastModified;
import std.json : JSONType, parseJSON;

struct ReplacementRule {
    string from;
    string to;
}

/// Разбирает JSON-объект словаря замен {"откуда": "куда"}.
/// Правила сортируются по длине ключа по убыванию, чтобы длинные фразы срабатывали раньше коротких.
ReplacementRule[] parseReplacementsJson(string content) {
    ReplacementRule[] rules;
    try {
        auto root = parseJSON(content);
        if (root.type != JSONType.object) return null;
        foreach (string k, val; root.object) {
            if (k.length == 0 || val.type != JSONType.string) continue;
            rules ~= ReplacementRule(k, val.str);
        }
    } catch (Exception) {
        return null;
    }

    rules.sort!((a, b) => a.from.length > b.from.length);
    return rules;
}

/// Загружает словарь замен из файла (по умолчанию replacements.json рядом с exe).
ReplacementRule[] loadReplacements(string path = "") {
    auto resolved = path.length ? path : resolvePath("replacements.json");
    if (!exists(resolved)) return null;
    try {
        return parseReplacementsJson(readText(resolved));
    } catch (Exception) {
        return null;
    }
}

/// Применяет список замен к распознанному тексту.
string applyReplacements(string text, const(ReplacementRule)[] rules) {
    if (text.length == 0 || rules.length == 0) return text;
    string result = text;
    foreach (ref r; rules) {
        result = result.replace(r.from, r.to);
    }
    return result;
}

/// Кэширующий загрузчик replacements.json (перечитывает файл только при изменении mtime).
struct ReplacementStore {
    private ReplacementRule[] m_rules;
    private SysTime m_lastMtime;
    private bool m_hasFile;

    string apply(string text) {
        auto path = resolvePath("replacements.json");
        if (!exists(path)) {
            m_rules = null;
            m_hasFile = false;
            return text;
        }
        try {
            auto mt = timeLastModified(path);
            if (!m_hasFile || mt != m_lastMtime) {
                m_rules = parseReplacementsJson(readText(path));
                m_lastMtime = mt;
                m_hasFile = true;
            }
        } catch (Exception) {
            return text;
        }
        return applyReplacements(text, m_rules);
    }
}

unittest {
    auto rules = parseReplacementsJson(`{"вишпер": "Whisper", "новая строка": "\n", "новая": "NEW"}`);
    assert(rules.length == 3);
    assert(rules[0].from == "новая строка");
    assert(applyReplacements("Привет вишпер новая строкатест", rules) == "Привет Whisper \nтест");
    assert(applyReplacements("обычный текст", null) == "обычный текст");
    assert(parseReplacementsJson("not json") is null);
}
