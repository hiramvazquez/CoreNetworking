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

    @Test("didReceive(data:) con Content-Length EXACTAMENTE 0 tampoco reporta progreso (no divide entre cero)")
    func inMemoryDownloadProgressSkippedWithExactlyZeroContentLength() async throws {
        // A diferencia del test de arriba (tarea inerte, `.response == nil`, expectedLength
        // == -1 vía el `?? -1`), este ejercita el límite EXACTO del guard `expectedLength >
        // 0`: una respuesta real con `Content-Length: 0`. Sin este test, `>` → `>=` deja
        // pasar `expectedLength == 0` y `Double(total) / Double(0)` produce `.infinity` —
        // `min(1.0, .infinity)` sigue siendo `1.0`, así que `onDownload(1.0)` SÍ se
        // llamaría, justo lo que este test demuestra que no debe pasar.
        let server = try LoopbackHTTPServer(body: Data())
        let task = try await realDataTask(from: server.url)
        try #require((task.response as? HTTPURLResponse)?.expectedContentLength == 0)

        let log = ProgressLog()
        let delegate = TaskDelegate(pinning: nil, progress: TransferProgress(onDownload: { log.append($0) }))
        delegate.urlSession(.shared, dataTask: task, didReceive: Data())

        #expect(log.values.isEmpty, "expectedContentLength == 0 no debe reportar progreso")
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

    @Test("sin HTTPURLResponse en la tarea (nil): se trata como fallo, NUNCA como éxito")
    func finishDownloadingWithoutHTTPResponseIsTreatedAsFailure() throws {
        // `downloadTask.response as? HTTPURLResponse` puede fallar por dos motivos: no es
        // `HTTPURLResponse`, o es `nil` — una tarea inerte (nunca resumida) cubre el segundo.
        // Sin `httpResponse` no hay status que consultar, así que `isSuccess` DEBE quedar en
        // `false` (la rama `else`): no hay forma de saber si el servidor respondió 2xx, y
        // tratarlo como éxito movería un cuerpo sin verificar a `destination`.
        let payload = Data("no debería llegar a destination".utf8)
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-noresponse-\(UUID().uuidString).bin")
        try payload.write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskdelegate-finish-noresponse-dest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let delegate = TaskDelegate(pinning: nil, progress: nil, destination: destination)
        delegate.urlSession(.shared, downloadTask: inertDownloadTask(), didFinishDownloadingTo: location)

        #expect(delegate.didMoveFile == true)
        #expect(delegate.fileMoveError == nil)
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "sin response fiable, destination no debe tocarse jamás"
        )
        #expect(!FileManager.default.fileExists(atPath: location.path), "el temporal debe descartarse, no moverse")
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

    // MARK: - isSameOrigin (qué cuenta como "mismo origen" para saneado de redirecciones)
    //
    // `RedirectSecurityTests` ejercita `isSameOrigin` solo indirectamente, a través de
    // `URLSessionTransport` con redirecciones reales — y todas esas redirecciones, cross- o
    // same-origin, comparten scheme y host (loopback), solo difieren en el puerto. Eso
    // nunca activa la rama `else { return false }` del guard (falla scheme O host): la
    // devuelve siempre el `return effectivePort(of: a) == effectivePort(of: b)` final. Estos
    // tests llaman a la función pura directamente para cubrir esa rama.

    @Test("isSameOrigin: mismo scheme, host y puerto (implícito) es el mismo origen")
    func isSameOriginTrueForIdenticalOrigin() {
        let a = URL(string: "https://api.example.com/a")!
        let b = URL(string: "https://api.example.com/b")!
        #expect(TaskDelegate.isSameOrigin(a, b))
    }

    @Test("isSameOrigin: distinto scheme NO es el mismo origen, aunque host y puerto coincidan")
    func isSameOriginFalseForDifferentScheme() {
        let a = URL(string: "https://api.example.com/a")!
        let b = URL(string: "http://api.example.com/a")!
        #expect(!TaskDelegate.isSameOrigin(a, b))
    }

    @Test("isSameOrigin: distinto host NO es el mismo origen, aunque scheme y puerto coincidan")
    func isSameOriginFalseForDifferentHost() {
        let a = URL(string: "https://api.example.com/a")!
        let b = URL(string: "https://evil.example.com/a")!
        #expect(!TaskDelegate.isSameOrigin(a, b))
    }

    @Test("isSameOrigin: distinto puerto explícito NO es el mismo origen")
    func isSameOriginFalseForDifferentPort() {
        let a = URL(string: "https://api.example.com:8443/a")!
        let b = URL(string: "https://api.example.com/a")!
        #expect(!TaskDelegate.isSameOrigin(a, b))
    }

    // MARK: - willPerformHTTPRedirection: caso degenerado sin URL utilizable

    // `.timeLimit`: si el guard desaparece, el `completionHandler` no se llama nunca y este
    // test se COLGARÍA en vez de fallar — en CI eso se come el timeout del job entero y no
    // dice por qué. Con el límite, una regresión sale como fallo con nombre en segundos.
    @Test(
        "followSanitizingCrossOrigin sin destinationURL utilizable: reenvía la request tal cual, sin colgarse",
        .timeLimit(.minutes(1))
    )
    func followSanitizingCrossOriginWithoutDestinationURLForwardsRequestUnchanged() async throws {
        // `request.url == nil` no ocurre nunca con un `newRequest` real que entrega
        // `URLSession` (siempre trae la URL de destino de la redirección), pero
        // `URLRequest.url` SIGUE siendo `Optional` a nivel de tipos — nada impide que un
        // valor así llegue aquí en el futuro (un test doble, una API que cambie). El guard
        // de `willPerformHTTPRedirection` cubre exactamente ese caso: sin `destinationURL`
        // no hay decisión de saneado que tomar, así que reenvía la request de la
        // redirección sin tocarla, en vez de dejar la tarea colgada sin completar nunca el
        // `completionHandler`.
        let delegate = TaskDelegate(pinning: nil, redirectPolicy: .followSanitizingCrossOrigin)
        let task = URLSession.shared.dataTask(with: URL(string: "https://start.test/a")!)
        let redirectResponse = try #require(
            HTTPURLResponse(
                url: URL(string: "https://start.test/a")!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://redirected-to.test/b"]
            )
        )
        var brokenRequest = URLRequest(url: URL(string: "https://redirected-to.test/b")!)
        brokenRequest.url = nil
        brokenRequest.setValue("Bearer secreto", forHTTPHeaderField: "Authorization")

        let received = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: brokenRequest
            ) { result in
                continuation.resume(returning: result)
            }
        }

        #expect(received != nil, "debe completar la redirección, nunca colgarse sin llamar al completionHandler")
        #expect(received?.url == nil, "sin destinationURL utilizable, la request se reenvía TAL CUAL, sin sanear")
        #expect(
            received?.value(forHTTPHeaderField: "Authorization") == "Bearer secreto",
            "reenviar 'tal cual' significa no tocar ni siquiera los headers sensibles en este caso degenerado"
        )
    }
}
