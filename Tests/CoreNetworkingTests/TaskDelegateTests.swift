import Foundation
import Testing

@testable import CoreNetworking

/// Cobertura de `TaskDelegate` MÁS ALLÁ del pinning (eso lo cubre
/// `PinningDelegateTests`): progreso de subida/descarga y el gate de 2xx en
/// `didFinishDownloadingTo` (ver el doc comment de `TaskDelegate` — ese
/// callback nunca lo dispara `session.download(for:delegate:)` en el SDK que
/// este paquete usa, así que `TransferTests` — que sí pasa por el pipeline
/// real — no lo ejercita jamás).
///
/// ## Cómo se fabrican los dobles
///
/// `URLSessionTask`/`URLSessionDataTask`/`URLSessionDownloadTask` son clases
/// de Foundation cuyo único inicializador propio (`init()`) está deprecado
/// desde macOS 10.15 — este paquete compila con `-warnings-as-errors`
/// (`SWIFT_STRICT_WARNINGS=1`), así que subclasearlas para inyectar una
/// `.response` a medida (como hace `PinningDelegateTests.EspacioConTrust`
/// con `URLProtectionSpace`, que SÍ tiene un init no deprecado) no compila
/// aquí sin bajar ese nivel.
///
/// En su lugar:
/// - `didSendBodyData`/`didWriteData` ignoran el parámetro `task` — vale
///   cualquier tarea real e inerte (`URLSession.shared.…(with:)`, nunca
///   resumida), igual que `PinningDelegateTests.tareaInerte()`.
/// - `didReceive(dataTask:didReceive:)` y `didFinishDownloadingTo` sí leen
///   `task.response`: para esos se ejecuta una descarga/petición REAL contra
///   `LoopbackHTTPServer` (de `TransferTests.swift`, mismo target) con la
///   API de completion-handler clásica, que entrega el `URLSessionTask` de
///   verdad — con su `.response` de verdad, status controlado por el
///   servidor — en vez de fabricarlo.
@Suite("TaskDelegate: progreso de transferencia y finalización de descarga a disco")
struct TaskDelegateTests {
    // MARK: - Fixtures compartidas

    private func inertDataTask(url: URL = URL(string: "https://task-delegate.test/x")!) -> URLSessionDataTask {
        URLSession.shared.dataTask(with: url)
    }

    private func inertDownloadTask(url: URL = URL(string: "https://task-delegate.test/x")!) -> URLSessionDownloadTask {
        URLSession.shared.downloadTask(with: url)
    }

    /// Ejecuta una descarga REAL (API de completion-handler, no `async`) y
    /// devuelve la tarea — con su `.response` ya poblado — junto con la
    /// ubicación temporal, todavía viva en el instante en que el completion
    /// handler resuelve la continuación (antes de que Foundation la borre).
    private func realDownload(from url: URL) async throws -> (task: URLSessionDownloadTask, location: URL) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var capturedTask: URLSessionDownloadTask?
        let location = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: url) { location, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: location)
            }
            capturedTask = task
            task.resume()
        }
        return (try #require(capturedTask), location)
    }

    /// Misma idea que `realDownload`, para `didReceive(dataTask:didReceive:)`
    /// — solo hace falta la tarea (con `.response` real), los chunks que
    /// llegan al delegado en el test son sintéticos.
    private func realDataTask(from url: URL) async throws -> URLSessionDataTask {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var capturedTask: URLSessionDataTask?
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let task = session.dataTask(with: url) { data, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            capturedTask = task
            task.resume()
        }
        return try #require(capturedTask)
    }

    // MARK: - didSendBodyData (progreso de subida)

    @Test("didSendBodyData reporta la fracción cuando totalBytesExpectedToSend > 0")
    func uploadProgressReportsFraction() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onUpload: { log.append($0) }))
        delegate.urlSession(
            .shared,
            task: inertDataTask(),
            didSendBodyData: 50,
            totalBytesSent: 50,
            totalBytesExpectedToSend: 200
        )
        #expect(log.values == [0.25])
    }

    @Test("didSendBodyData clampa a 1.0 aunque el enviado supere el esperado")
    func uploadProgressClampsToOne() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onUpload: { log.append($0) }))
        delegate.urlSession(
            .shared,
            task: inertDataTask(),
            didSendBodyData: 10,
            totalBytesSent: 300,
            totalBytesExpectedToSend: 200
        )
        #expect(log.values == [1.0])
    }

    @Test("didSendBodyData con totalBytesExpectedToSend <= 0 no reporta nada")
    func uploadProgressSkippedWithoutExpectedTotal() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onUpload: { log.append($0) }))
        for total: Int64 in [0, -1] {
            delegate.urlSession(
                .shared,
                task: inertDataTask(),
                didSendBodyData: 10,
                totalBytesSent: 10,
                totalBytesExpectedToSend: total
            )
        }
        #expect(log.values.isEmpty, "sin total esperado no hay fracción que calcular")
    }

    @Test("didSendBodyData sin onUpload configurado no crashea")
    func uploadProgressWithoutCallbackDoesNotCrash() {
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { _ in }))
        delegate.urlSession(
            .shared,
            task: inertDataTask(),
            didSendBodyData: 10,
            totalBytesSent: 10,
            totalBytesExpectedToSend: 20
        )
        let delegateSinProgreso = TaskDelegate(pinning: nil, progress: nil)
        delegateSinProgreso.urlSession(
            .shared,
            task: inertDataTask(),
            didSendBodyData: 10,
            totalBytesSent: 10,
            totalBytesExpectedToSend: 20
        )
    }

    // MARK: - didReceive(dataTask:didReceive:) (progreso de descarga en memoria)

    @Test("didReceive(data:) acumula bytes entre llamadas y reporta fracción monótona")
    func inMemoryDownloadProgressAccumulates() async throws {
        let server = try LoopbackHTTPServer(headers: ["Content-Length": "400"], body: Data(repeating: 0, count: 400))
        let task = try await realDataTask(from: server.url)
        try #require((task.response as? HTTPURLResponse)?.expectedContentLength == 400)

        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))

        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0, count: 100))
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0, count: 100))
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0, count: 200))

        #expect(log.values == [0.25, 0.5, 1.0])
    }

    @Test("didReceive(data:) sin Content-Length (o <= 0) nunca reporta progreso")
    func inMemoryDownloadProgressSkippedWithoutContentLength() {
        // Una tarea inerte, nunca resumida: `.response` es `nil`, exactamente
        // el mismo caso que `expectedContentLength <= 0` para este guard.
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))
        delegate.urlSession(.shared, dataTask: inertDataTask(), didReceive: Data(repeating: 0, count: 10))
        #expect(log.values.isEmpty)
    }

    @Test("didReceive(data:) sin onDownload configurado no crashea")
    func inMemoryDownloadProgressWithoutCallbackDoesNotCrash() {
        let delegate = TaskDelegate(pinning: nil, progress: nil)
        delegate.urlSession(.shared, dataTask: inertDataTask(), didReceive: Data(repeating: 0, count: 10))
    }

    // MARK: - didWriteData (progreso de descarga a disco)

    @Test("didWriteData reporta la fracción cuando totalBytesExpectedToWrite > 0")
    func diskDownloadProgressReportsFraction() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))
        delegate.urlSession(
            .shared,
            downloadTask: inertDownloadTask(),
            didWriteData: 25,
            totalBytesWritten: 25,
            totalBytesExpectedToWrite: 100
        )
        #expect(log.values == [0.25])
    }

    @Test("didWriteData clampa a 1.0 aunque lo escrito supere lo esperado")
    func diskDownloadProgressClampsToOne() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))
        delegate.urlSession(
            .shared,
            downloadTask: inertDownloadTask(),
            didWriteData: 5,
            totalBytesWritten: 150,
            totalBytesExpectedToWrite: 100
        )
        #expect(log.values == [1.0])
    }

    @Test("didWriteData con totalBytesExpectedToWrite <= 0 no reporta nada")
    func diskDownloadProgressSkippedWithoutExpectedTotal() {
        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))
        for total: Int64 in [0, -1] {
            delegate.urlSession(
                .shared,
                downloadTask: inertDownloadTask(),
                didWriteData: 5,
                totalBytesWritten: 5,
                totalBytesExpectedToWrite: total
            )
        }
        #expect(log.values.isEmpty)
    }

    @Test("didWriteData sin onDownload configurado no crashea")
    func diskDownloadProgressWithoutCallbackDoesNotCrash() {
        let delegate = TaskDelegate(pinning: nil, progress: nil)
        delegate.urlSession(
            .shared,
            downloadTask: inertDownloadTask(),
            didWriteData: 5,
            totalBytesWritten: 5,
            totalBytesExpectedToWrite: 10
        )
    }

    // MARK: - didFinishDownloadingTo (gate de 2xx, CN-04/hotfix de hoy)

    @Test("sin destination configurado (caso de `send`), no toca nada y no crashea")
    func finishDownloadingWithoutDestinationIsNoOp() {
        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: nil)
        let bogusLocation = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        delegate.urlSession(.shared, downloadTask: inertDownloadTask(), didFinishDownloadingTo: bogusLocation)
        #expect(delegate.didMoveFile == false)
        #expect(delegate.fileMoveError == nil)
    }

    @Test("2xx: mueve el temporal a destination y lo marca como movido")
    func finishDownloadingOnSuccessMovesFile() async throws {
        let payload = Data(repeating: 0xAB, count: 64)
        let server = try LoopbackHTTPServer(body: payload)
        let (task, location) = try await realDownload(from: server.url)
        try #require((task.response as? HTTPURLResponse)?.statusCode == 200)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-ok-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: location)

        #expect(delegate.didMoveFile == true)
        #expect(delegate.fileMoveError == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == payload)
        #expect(!FileManager.default.fileExists(atPath: location.path), "el temporal debe moverse, no copiarse")
    }

    @Test("2xx con un fichero ya existente en destination: lo sustituye")
    func finishDownloadingOnSuccessReplacesExistingFile() async throws {
        let payload = Data(repeating: 0xCD, count: 32)
        let server = try LoopbackHTTPServer(body: payload)
        let (task, location) = try await realDownload(from: server.url)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-replace-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("contenido viejo".utf8).write(to: destination)

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: location)

        #expect(delegate.didMoveFile == true)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("non-2xx: descarta el temporal, NO toca destination, pero sigue marcando didMoveFile")
    func finishDownloadingOnHTTPErrorDiscardsTemporary() async throws {
        let server = try LoopbackHTTPServer(statusCode: 404, body: Data("not found".utf8))
        let (task, location) = try await realDownload(from: server.url)
        try #require((task.response as? HTTPURLResponse)?.statusCode == 404)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-404-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: location)

        // `didMoveFile` documenta "ya se resolvió qué hacer con el
        // temporal" (moverlo o descartarlo) — el nombre no implica éxito de
        // escritura en `destination`; el propio código lo marca `true` en
        // AMBAS ramas del `if isSuccess`.
        #expect(delegate.didMoveFile == true)
        #expect(delegate.fileMoveError == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "un 404 nunca debe escribir destination")
        #expect(!FileManager.default.fileExists(atPath: location.path), "el temporal de un error se descarta")
    }

    @Test("non-2xx conserva intacto un fichero preexistente en destination")
    func finishDownloadingOnHTTPErrorPreservesExistingDestination() async throws {
        let server = try LoopbackHTTPServer(statusCode: 500, body: Data("server error".utf8))
        let (task, location) = try await realDownload(from: server.url)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-500-preexisting-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let original = Data("no debe perderse".utf8)
        try original.write(to: destination)

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: location)

        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("si mover el temporal falla, fileMoveError se registra y didMoveFile queda en false")
    func finishDownloadingRecordsFileMoveError() async throws {
        let server = try LoopbackHTTPServer(body: Data("ok".utf8))
        // El `task` es real (2xx real), pero la `location` que le pasamos al
        // delegado es una que NUNCA existió — fuerza a `moveItem` a fallar,
        // exactamente como si el temporal hubiera desaparecido entre que
        // Foundation avisa y el delegado intenta moverlo.
        let (task, _) = try await realDownload(from: server.url)
        let bogusLocation = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-moveerror-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: bogusLocation)

        #expect(delegate.fileMoveError != nil)
        #expect(delegate.didMoveFile == false, "si moveItem lanza, no se llega a marcar como movido")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
