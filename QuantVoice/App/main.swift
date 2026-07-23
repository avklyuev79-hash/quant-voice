//
//  main.swift
//  Quant Voice
//
//  Запуск без storyboard и без @main-обёртки SwiftUI: приложение живёт
//  в menu bar, главного окна нет, поэтому классическая точка входа AppKit.
//  Верхнеуровневый код в main.swift исполняется на главном акторе (SE-0343) —
//  создание @MainActor-делегата здесь корректно.
//

import AppKit

let app = NSApplication.shared

// Делегат обязан пережить время жизни приложения — держим его
// в глобальной константе, а не только в слабом свойстве app.delegate.
let delegate = AppDelegate()
app.delegate = delegate

// .accessory дублирует LSUIElement из Info.plist. Подстраховка на случай
// запуска голого бинаря без бандла (например, при отладке): приложение
// всё равно не появится в Dock и не будет красть фокус.
_ = app.setActivationPolicy(.accessory)

app.run()
