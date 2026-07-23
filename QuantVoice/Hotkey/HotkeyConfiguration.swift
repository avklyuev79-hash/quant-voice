//
//  HotkeyConfiguration.swift
//  Quant Voice
//
//  Модель комбинации клавиш (ТЗ 5.5): Codable для хранения в настройках,
//  человекочитаемое представление («⌥Space»), проверка конфликтов с известными
//  системными шорткатами.
//
//  Модификаторы храним собственным OptionSet, а не сырыми CGEventFlags:
//  во флагах события намешаны биты, которые для хоткея — шум (Caps Lock,
//  numeric pad, различие левый/правый Option). Нормализация в один тип
//  делает сравнение «событие == конфигурация» точным и сериализацию стабильной.
//

import CoreGraphics
import Foundation

/// Виртуальные коды часто используемых клавиш (раскладка ANSI).
/// Код клавиши не зависит от текущей раскладки — ⌥Space остаётся ⌥Space
/// и в русской, и в английской.
public enum KeyCodes {
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let tab: UInt16 = 48
    public static let returnKey: UInt16 = 36
    /// Клавиша `~` слева от единицы. Удобна для удержания: край клавиатуры,
    /// достаётся мизинцем, не конфликтует с системными сочетаниями.
    public static let grave: UInt16 = 50
    /// Буква D. Несущая клавиша дефолтного хоткея ⌃⌥D.
    public static let d: UInt16 = 2
    /// Клавиша 🌐 (fn). Особая: приходит не как keyDown/keyUp, а как
    /// `flagsChanged` с флагом `maskSecondaryFn`. Обрабатывается отдельной
    /// веткой в мониторе — см. `HotkeyMonitor.handleGlobeLocked`.
    public static let globe: UInt16 = 63
}

/// Комбинация клавиш: один несущий keyCode + модификаторы.
public struct HotkeyConfiguration: Codable, Hashable, Sendable, CustomStringConvertible {

    /// Нормализованные модификаторы. UInt8-рв — компактная и стабильная
    /// сериализация (кодируется одним числом).
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Нормализация флагов CGEvent: берём только четыре смысловых
        /// модификатора, игнорируем Caps Lock / fn / numeric pad и
        /// различие левых/правых клавиш.
        public init(cgFlags: CGEventFlags) {
            var value: Modifiers = []
            if cgFlags.contains(.maskControl) { value.insert(.control) }
            if cgFlags.contains(.maskAlternate) { value.insert(.option) }
            if cgFlags.contains(.maskShift) { value.insert(.shift) }
            if cgFlags.contains(.maskCommand) { value.insert(.command) }
            self = value
        }

        /// Символы в каноническом для macOS порядке: ⌃⌥⇧⌘.
        public var displayString: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Дефолтный хоткей — ⌃⌥D.
    ///
    /// История выбора (каждый шаг — по факту с живой машины, не по догадке):
    /// 1. `⌥Space` из ТЗ — Siri перехватывает раньше `CGEventTap`, не сработать.
    /// 2. `⌥\`` — на ISO-клавиатуре печатает `§`, да и две клавиши для
    ///    удержания неудобны.
    /// 3. `⌃⌥D` — три условия сразу: система его не занимает (⌘D — закладки,
    ///    ⌃⌘D — словарь, ⌥⌘D — Dock, а ⌃⌥D свободен), буква D мнемонична
    ///    («диктовка»), и обе клавиши-модификатора лежат под левой рукой.
    ///
    /// Основной способ ввода всё же удержание 🌐 — эта комбинация запасная
    /// и заодно тестовая: на ней проверяется, что перехват вообще работает.
    public static let defaultPrimary = HotkeyConfiguration(keyCode: KeyCodes.d, modifiers: [.control, .option])
    /// Второй язык — ⌃⌥⇧D (ТЗ 6.5).
    public static let defaultSecondary = HotkeyConfiguration(keyCode: KeyCodes.d, modifiers: [.control, .option, .shift])

    /// Совпадает ли комбинация с событием клавиатуры (после нормализации флагов).
    /// Сравнение модификаторов — строгое равенство: ⌥Space не срабатывает
    /// на ⌥⇧Space и наоборот.
    public func matches(keyCode: UInt16, modifiers: Modifiers) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    /// Хоткей без модификаторов перехватывал бы обычную печать —
    /// UI настроек должен такое отвергать.
    public var hasModifiers: Bool { !modifiers.isEmpty }

    /// «⌥Space», «⌃⌥⇧⌘K» и т.п.
    public var displayString: String {
        modifiers.displayString + Self.keyName(for: keyCode)
    }

    public var description: String { displayString }

    // MARK: - Конфликты с системными шорткатами

    /// Известные системные комбинации. Список — лучшее, что можно сделать
    /// без приватных API: реальные назначения пользователя лежат в
    /// com.apple.symbolichotkeys и меняются от машины к машине, надёжного
    /// публичного способа их прочитать нет. Поэтому проверка — best effort,
    /// как и оговорено в ТЗ («по возможности»).
    private static let knownSystemShortcuts: [(hotkey: HotkeyConfiguration, purpose: String)] = [
        // Siri перехватывает ⌥Space раньше CGEventTap — заглотить не получится.
        // Проверено на macOS 26.5 (19.07.2026), из-за этого сменён дефолт.
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.option]), "Siri (⌥Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.command]), "Spotlight (⌘Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.command, .option]), "Поиск Finder (⌥⌘Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.control]), "Смена источника ввода (⌃Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.control, .option]), "Предыдущий источник ввода (⌃⌥Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.space, modifiers: [.control, .command]), "«Эмодзи и символы» (⌃⌘Space)"),
        (HotkeyConfiguration(keyCode: KeyCodes.tab, modifiers: [.command]), "Переключение приложений (⌘Tab)"),
        (HotkeyConfiguration(keyCode: 12, modifiers: [.command]), "Завершить приложение (⌘Q)"),
        (HotkeyConfiguration(keyCode: 20, modifiers: [.command, .shift]), "Снимок экрана (⇧⌘3)"),
        (HotkeyConfiguration(keyCode: 21, modifiers: [.command, .shift]), "Снимок области (⇧⌘4)"),
        (HotkeyConfiguration(keyCode: 23, modifiers: [.command, .shift]), "Запись экрана (⇧⌘5)"),
    ]

    /// Описание системного шортката, с которым конфликтует комбинация.
    /// nil — известных конфликтов нет (что не гарантирует их отсутствие).
    public func systemConflictDescription() -> String? {
        Self.knownSystemShortcuts.first { $0.hotkey == self }?.purpose
    }

    // MARK: - Имена клавиш

    /// Имена по ANSI-US. Для несущей клавиши хоткея этого достаточно;
    /// раскладко-зависимое отображение (через UCKeyTranslate, как в
    /// Quant Keyboard) можно добавить позже, не трогая модель.
    private static let keyNames: [UInt16: String] = [
        // Служебные
        49: "Space", 36: "↩", 48: "⇥", 53: "Esc", 51: "⌫", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Функциональные
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // Буквы (ANSI)
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        // Цифры
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        // Пунктуация
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
    ]

    /// Не private: используется мониторингом для читаемых записей в логе.
    public static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "#\(keyCode)"
    }
}

// MARK: - Привязка хоткея к языку

/// Хоткей + язык, который он фиксирует (ТЗ 6.5: язык задаётся явно, хоткеем).
public struct HotkeyAssignment: Codable, Hashable, Sendable {
    public var hotkey: HotkeyConfiguration
    public var language: RecognitionLanguage

    public init(hotkey: HotkeyConfiguration, language: RecognitionLanguage) {
        self.hotkey = hotkey
        self.language = language
    }

    /// Дефолт: ⌥` — русский, ⌥⇧` — английский.
    /// (В ТЗ был ⌥Space, но его перехватывает Siri — см. `defaultPrimary`.)
    /// Третий хоткей на .auto пользователь добавляет в настройках сам.
    public static let defaults: [HotkeyAssignment] = [
        HotkeyAssignment(hotkey: .defaultPrimary, language: .russian),
        HotkeyAssignment(hotkey: .defaultSecondary, language: .english),
    ]
}
