module i18n;

import core.atomic : atomicLoad, atomicStore;
import std.string : strip, toLower;

enum UiLang : int {
    en = 0,
    ru = 1,
}

private shared int g_uiLang = UiLang.en;

string normalizeUiLanguage(string lang) {
    auto l = lang.strip().toLower();
    if (l == "ru" || l == "russian") return "ru";
    return "en";
}

void setUiLanguage(string lang) {
    atomicStore(g_uiLang, normalizeUiLanguage(lang) == "ru" ? cast(int) UiLang.ru : cast(int) UiLang.en);
}

string getUiLanguage() nothrow {
    return isRu() ? "ru" : "en";
}

bool isRu() nothrow @nogc {
    return atomicLoad(g_uiLang) == UiLang.ru;
}

string tr(string en, string ru) nothrow @nogc {
    return isRu() ? ru : en;
}

unittest {
    auto prev = getUiLanguage();
    scope (exit) setUiLanguage(prev);

    assert(normalizeUiLanguage("") == "en");
    assert(normalizeUiLanguage("EN") == "en");
    assert(normalizeUiLanguage("ru") == "ru");
    assert(normalizeUiLanguage("Russian") == "ru");

    setUiLanguage("en");
    assert(!isRu());
    assert(tr("Hello", "Привет") == "Hello");

    setUiLanguage("ru");
    assert(isRu());
    assert(tr("Hello", "Привет") == "Привет");
}
