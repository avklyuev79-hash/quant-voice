//
//  ModelSource.swift
//  QuantVoiceModels
//
//  Откуда качать модель. Список источников, а не один захардкоженный хост.
//
//  Причина простая: huggingface.co из России режется провайдерами, а модель
//  без загрузки — это приложение, которое не работает вообще. Поэтому
//  источников несколько, и приложение перебирает их по порядку, пока
//  какой-нибудь не ответит.
//
//  ⚠️ Зеркала — это чужие серверы, и слепо доверять им нельзя: файл модели
//  исполняется на машине пользователя. Поэтому размер каждого скачанного
//  файла сверяется с тем, что заявил основной индекс, а сам список зеркал
//  зашит в код и не берётся из сети.
//

import Foundation

public struct ModelSource: Equatable, Sendable, Identifiable {
    public var id: String { host }

    /// Хост без схемы: «huggingface.co».
    public let host: String
    /// Человеческое имя для UI и лога.
    public let title: String

    public init(host: String, title: String) {
        self.host = host
        self.title = title
    }

    /// Адрес списка файлов варианта.
    public func treeURL(repository: String, variant: String) -> URL? {
        URL(string: "https://\(host)/api/models/\(repository)/tree/main/\(variant)?recursive=true")
    }

    /// Адрес конкретного файла.
    public func fileURL(repository: String, path: String) -> URL? {
        URL(string: "https://\(host)/\(repository)/resolve/main/\(path)")
    }

    // MARK: - Известные источники

    /// Основной. Всё остальное — запасные пути к тем же файлам.
    public static let huggingFace = ModelSource(host: "huggingface.co",
                                                title: "Hugging Face")

    /// Зеркало Hugging Face с той же схемой адресов. Живёт для регионов,
    /// где основной хост недоступен, и повторяет его API один в один.
    public static let hfMirror = ModelSource(host: "hf-mirror.com",
                                             title: "Зеркало hf-mirror.com")

    /// Порядок перебора: сначала оригинал, потом зеркала.
    public static let all: [ModelSource] = [huggingFace, hfMirror]
}
