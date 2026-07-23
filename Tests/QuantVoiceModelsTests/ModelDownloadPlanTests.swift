//
//  ModelDownloadPlanTests.swift
//  QuantVoiceModelsTests
//

import XCTest
@testable import QuantVoiceModels

final class ModelDownloadPlanTests: XCTestCase {

    // MARK: - Разбор ответа Hugging Face

    private let listing = """
    [
      {"type":"directory","path":"openai_whisper-small_216MB/AudioEncoder.mlmodelc"},
      {"type":"file","path":"openai_whisper-small_216MB/config.json","size":1234},
      {"type":"file","path":"openai_whisper-small_216MB/AudioEncoder.mlmodelc/weights/weight.bin",
       "size":135,"lfs":{"size":441000000}}
    ]
    """.data(using: .utf8)!

    func testParsesFilesAndSkipsDirectories() throws {
        let files = try ModelDownloadPlan.parseTree(listing)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first?.path, "openai_whisper-small_216MB/config.json")
    }

    /// У LFS-файла в `size` лежит размер указателя (~сотня байт), а настоящий
    /// размер — во вложенном `lfs`. Перепутать их значит счесть оборванный
    /// 420-мегабайтный файл готовым.
    func testLFSSizeWinsOverPointerSize() throws {
        let files = try ModelDownloadPlan.parseTree(listing)
        XCTAssertEqual(files.last?.size, 441_000_000)
    }

    func testEmptyOrBrokenListingThrows() {
        XCTAssertThrowsError(try ModelDownloadPlan.parseTree("[]".data(using: .utf8)!))
        XCTAssertThrowsError(try ModelDownloadPlan.parseTree("{}".data(using: .utf8)!))
    }

    func testRelativePathStripsVariantPrefix() {
        let file = ModelFile(path: "openai_whisper-small_216MB/config.json", size: 1)
        XCTAssertEqual(file.relativePath(strippingVariant: "openai_whisper-small_216MB"),
                       "config.json")
    }

    // MARK: - Решение по каждому файлу

    /// Это и делает загрузку перезапускаемой: оборвалось на десятом файле —
    /// первые девять не трогаются.
    func testCompleteFileIsSkipped() {
        XCTAssertEqual(ModelDownloadPlan.action(expected: 100, existing: 100), .skip)
    }

    func testPartialFileResumes() {
        XCTAssertEqual(ModelDownloadPlan.action(expected: 100, existing: 40), .resume(from: 40))
    }

    func testMissingOrOversizedFileStartsOver() {
        XCTAssertEqual(ModelDownloadPlan.action(expected: 100, existing: nil), .downloadFromScratch)
        XCTAssertEqual(ModelDownloadPlan.action(expected: 100, existing: 0), .downloadFromScratch)
        XCTAssertEqual(ModelDownloadPlan.action(expected: 100, existing: 140), .downloadFromScratch)
    }

    // MARK: - Токенайзер

    func testTokenizerRepositoryMatchesVariant() {
        XCTAssertEqual(ModelDownloadPlan.tokenizerRepository(forVariant: "openai_whisper-small_216MB"),
                       "openai/whisper-small")
        XCTAssertEqual(ModelDownloadPlan.tokenizerRepository(forVariant: "openai_whisper-large-v3-v20240930_626MB"),
                       "openai/whisper-large-v3")
        XCTAssertEqual(ModelDownloadPlan.tokenizerRepository(forVariant: "openai_whisper-large-v2"),
                       "openai/whisper-large-v2")
        // Неизвестный вариант не должен остаться без токенайзера вовсе.
        XCTAssertEqual(ModelDownloadPlan.tokenizerRepository(forVariant: "что-то-новое"),
                       "openai/whisper-large-v3")
    }

    // MARK: - Источники

    func testSourceBuildsHuggingFaceStyleURLs() {
        let source = ModelSource.huggingFace
        XCTAssertEqual(source.treeURL(repository: "argmaxinc/whisperkit-coreml",
                                      variant: "openai_whisper-small_216MB")?.absoluteString,
                       "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small_216MB?recursive=true")
        XCTAssertEqual(source.fileURL(repository: "openai/whisper-small",
                                      path: "tokenizer.json")?.absoluteString,
                       "https://huggingface.co/openai/whisper-small/resolve/main/tokenizer.json")
    }

    /// Зеркало повторяет схему адресов оригинала — иначе перебор источников
    /// не имел бы смысла.
    func testMirrorUsesSameURLScheme() {
        let original = ModelSource.huggingFace.fileURL(repository: "r", path: "f")!.path
        let mirror = ModelSource.hfMirror.fileURL(repository: "r", path: "f")!.path
        XCTAssertEqual(original, mirror)
        XCTAssertEqual(ModelSource.all.first, .huggingFace, "оригинал пробуем первым")
    }
}
