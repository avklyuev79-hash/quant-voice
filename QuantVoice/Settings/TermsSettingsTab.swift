//
//  TermsSettingsTab.swift
//  Quant Voice
//
//  Вкладка «Термины» окна настроек (ТЗ 6.6): список, добавление, правка,
//  удаление, импорт/экспорт JSON. Без изысков — рабочий редактор для беты.
//
//  Работает напрямую с TermsStore: хранилище само наблюдаемое, дублировать
//  его состояние в SettingsModel было бы вторым источником правды.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuantVoiceTerms

struct TermsSettingsTab: View {
    var store: TermsStore

    @State private var selection = Set<UUID>()
    /// Термин в редакторе. nil — редактор закрыт; новый термин — свежий Term
    /// с пустым canonical (сохранение недоступно, пока поле пустое).
    @State private var editedTerm: Term?
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var infoMessage = ""
    /// Поиск по встроенному словарю. Он большой (сотни записей), без фильтра
    /// в нём не сориентироваться.
    @State private var builtinSearch = ""

    /// Встроенный словарь — снимок один раз при создании вкладки. `Term.builtIn`
    /// пересобирается на каждом обращении, а в теле View обращений много.
    private let builtin = Term.builtIn

    var body: some View {
        Form {
            Section("Словарь терминов") {
                List(selection: $selection) {
                    ForEach(store.terms) { term in
                        row(for: term)
                            .tag(term.id)
                    }
                }
                .frame(minHeight: 190)

                HStack {
                    Button("Добавить…") { editedTerm = Term(canonical: "") }
                    Button("Изменить…") { editSelected() }
                        .disabled(selection.count != 1)
                    Button("Удалить") {
                        store.remove(ids: selection)
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                }

                Text("Термины подсказываются модели до распознавания, а варианты произношения (ослышки) заменяются на каноническое написание после. Закреплённые термины — всегда в подсказке.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Встроенный словарь — \(builtin.count)") {
                TextField("Поиск: бренд или аббревиатура", text: $builtinSearch)
                    .textFieldStyle(.roundedBorder)

                List {
                    ForEach(filteredBuiltin) { term in
                        row(for: term)
                    }
                }
                .frame(minHeight: 150)

                Text("Бренды и устойчивые сокращения, зашитые в приложение и обновляемые вместе с ним. Правке не подлежат — это общий словарь для всех. Твой личный термин с тем же написанием перекрывает встроенный.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Файл словаря") {
                HStack {
                    Button("Импортировать JSON…") { importJSON() }
                    Button("Экспортировать JSON…") { exportJSON() }
                    Button("Перечитать файл") {
                        store.reloadFromDisk()
                        selection.removeAll()
                        infoMessage = "Словарь перечитан с диска."
                    }
                }
                if !infoMessage.isEmpty {
                    Text(infoMessage)
                        .font(.caption)
                }
                Text("Словарь лежит в ~/Library/Application Support/QuantVoice/terms.json. Его можно править руками — «Перечитать файл» подхватит правки без перезапуска.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editedTerm) { term in
            TermEditorView(term: term) { saved in
                store.upsert(saved)
            }
        }
        .alert("Ошибка", isPresented: $showError) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private func row(for term: Term) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(term.canonical)
                if term.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !term.variants.isEmpty {
                Text(term.variants.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Встроенный словарь под строку поиска: совпадение по каноническому
    /// написанию или любому варианту. Пустой запрос — весь список.
    private var filteredBuiltin: [Term] {
        let query = builtinSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return builtin }
        return builtin.filter { term in
            term.canonical.localizedCaseInsensitiveContains(query)
                || term.variants.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func editSelected() {
        guard let id = selection.first,
              let term = store.terms.first(where: { $0.id == id }) else { return }
        editedTerm = term
    }

    // MARK: - Импорт и экспорт

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try store.importTerms(from: data)
            infoMessage = "Импорт: добавлено \(result.added), обновлено \(result.updated)."
        } catch {
            errorMessage = "Не удалось импортировать: \(error.localizedDescription)"
            showError = true
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "quantvoice-terms.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url)
            infoMessage = "Словарь экспортирован."
        } catch {
            errorMessage = "Не удалось экспортировать: \(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - Редактор термина

private struct TermEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var canonical: String
    @State private var language: String // "" — не задан
    @State private var pinned: Bool
    @State private var variantsText: String

    private let original: Term
    private let onSave: (Term) -> Void

    init(term: Term, onSave: @escaping (Term) -> Void) {
        original = term
        self.onSave = onSave
        _canonical = State(initialValue: term.canonical)
        _language = State(initialValue: term.language ?? "")
        _pinned = State(initialValue: term.pinned)
        _variantsText = State(initialValue: term.variants.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original.canonical.isEmpty ? "Новый термин" : "Термин")
                .font(.headline)

            TextField("Каноническое написание, например Claude Cowork", text: $canonical)

            Picker("Язык", selection: $language) {
                Text("не задан").tag("")
                Text("русский").tag("ru")
                Text("английский").tag("en")
            }

            Toggle("Всегда подсказывать модели (закрепить)", isOn: $pinned)

            Text("Варианты произношения и ослышки — по одному в строке:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $variantsText)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canonical.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        var term = original
        term.canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        term.language = language.isEmpty ? nil : language
        term.pinned = pinned
        term.variants = variantsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(term)
        dismiss()
    }
}
