# Changelog — CoreNetworking

Todos los cambios notables de este paquete se documentan en este fichero. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el versionado,
[SemVer](https://semver.org/lang/es/).

## [Unreleased]

## [1.2.1] - 2026-09-05

### Documentación

- **`BaseRequest.timeout` documenta que es un timeout de INACTIVIDAD**, no un techo a la
  duración total, y que con `waitsForConnectivity` —el default del paquete— queda suprimido
  del todo contra un servidor conectado que no manda bytes. Medido contra un host real, no
  inferido (`LiveNetworkTests`). El techo efectivo en ese caso es
  `timeoutIntervalForResource`, que `enforceSecurityFloor(on:)` fija en 60 s frente a los 7
  días de Foundation.

### Cambiado

- **CI**: nuevo job `red-real` (`.github/workflows/ci.yml`), con su propio `schedule`
  diario y `workflow_dispatch` — nunca en push/PR, mismo patrón que `mutation` (que ahora
  distingue su propio cron semanal del nuevo cron diario vía `github.event.schedule`, para
  no dispararse el uno al otro ni duplicar la corrida cara de `mutation`). Ejecuta
  `LiveNetworkTests` (ver más abajo) contra `dummyjson.com`/`httpbin.org`.

### Pruebas

- `Tests/CoreNetworkingTests/LiveNetworkTests.swift`: suite de red REAL, opt-in
  (`CORENETWORKING_LIVE_NETWORK_TESTS=1 swift test --filter LiveNetworkTests`), apagada por
  defecto con `@Suite(.enabled(if:))` — `swift test` a secas sigue en 226 tests verdes y
  ~0,1 s, sin tocar la red. Cierra el hueco que ningún mock puede cerrar: `MockURLProtocol`
  sustituye el transporte DESPUÉS de la fase TLS, así que el pinning nunca había visto un
  `didReceive challenge:` real (`PinningPipelineTests` lo documenta explícitamente como
  fuera de su alcance). Diez tests, dos backends:
  - `dummyjson.com` (el backend de referencia de AppStarter): un payload real decodifica
    con el `JSONDecoder` del paquete; un 404 real produce `.notFound` con el cuerpo
    accesible por `decodeBody`; y el pinning, contra un handshake TLS en vivo, ACEPTA el
    pin SPKI que el propio handshake acaba de servir (calculado en el momento, no fijado a
    mano — no queda obsoleto cuando el backend rote su clave) y RECHAZA uno que nunca puede
    coincidir, con `.untrustedServer`.
  - `httpbin.org` (comportamientos de transporte que `dummyjson.com` no ofrece):
    redirecciones encadenadas, `Content-Encoding: gzip` transparente, un cuerpo servido en
    más de un frame de red, un `Retry-After` real en minúsculas (HTTP/2, no el
    `"Retry-After"` que solo un mock escribiría así), un 429 real, y un timeout real de
    `BaseRequest.timeout` contra una respuesta deliberadamente lenta.
  - Hallazgo de escribir el último: `waitsForConnectivity = true` (el default del paquete)
    SUPRIME el timeout de inactividad por request contra un servidor que sigue conectado
    pero no manda ni un byte durante la espera — verificado empíricamente, invisible para
    cualquier mock. El test lo documenta y fija `waitsForConnectivity = false` para poder
    seguir probando `BaseRequest.timeout` en menos de un segundo.
  - Se descartó un servidor HTTPS local con certificado autofirmado para el pinning (la
    opción más determinista): la única vía pública para un `SecIdentity` de servidor pasa
    por el llavero, y un runner de CI headless puede colgarse indefinidamente en el diálogo
    de control de acceso la primera vez que se usa una clave privada importada. Ver el doc
    comment del propio fichero de test para el razonamiento completo.
  - Cada test anota (`Issue.record`, sin cambiar si pasa o falla) si un fallo pinta a
    backend caído o a una regresión real de CoreNetworking, para que el job de CI (`red-real`,
    ver más abajo) no confunda "dummyjson.com está caído" con "nuestro pinning dejó de
    funcionar".
- Tests de interacción (espía) para tres contratos de `RequestInterceptor`/`RequestRetrier`
  que ningún test verificaba — un refactor podía invertir o borrar la línea que los cumple y
  la suite seguía en verde:
  - `RequestInterceptor.didFail`: "called exactly once per failed attempt, regardless of
    which stage failed" tenía test para 3 de los 7 sitios de `APIService` que notifican un
    fallo (status non-2xx, error de transporte, `willSend` que lanza). `InterceptorTests.swift`
    añade los 4 que faltaban — `PinningFailure` → `.untrustedServer`, `URLError(.cancelled)` →
    `.cancelled`, `CancellationError` → `.cancelled`, y el catch-all → `.unexpected` con
    `underlying` preservado — cada uno afirmando `didFail` EXACTAMENTE una vez y `didReceive`
    CERO veces (el transporte nunca entregó respuesta). El séptimo camino, una respuesta que no
    es `HTTPURLResponse`, queda sin test: `HTTPTransport.send`/`.download` declaran su retorno
    como `HTTPURLResponse` (no `URLResponse`), así que ningún transporte conforme —
    `InMemoryTransport` incluido— puede producir ahí un valor que falle `as? HTTPURLResponse`;
    el `guard` de `APIService.performOnce` que lo comprueba es código muerto con la forma
    actual del protocolo.
  - Precedencia `retriers` → `retryPolicy` (`RequestRetrier`'s doc): `RetrierTests.swift` prueba
    que `retryPolicy.shouldRetry` NO se consulta cuando un retrier ya decidió, que SÍ se
    consulta (tras todos los retriers, en su orden) cuando todos responden `.doNotRetry`, y que
    `RetryDecision.retry` (a través de un retrier, no del camino sin retriers) prefiere el
    `Retry-After` del servidor sobre el backoff de `RetryPolicy`, y usa ese backoff cuando el
    servidor no manda el header — las tres combinaciones documentadas en `RetryDecision` que
    antes solo cubría, parcialmente, el camino sin retriers.
  - `TokenRefreshRetrier` solo dispara el refresh en el primer intento (su doc: un 401 en un
    intento posterior significa que el token recién refrescado tampoco vale, y refrescar de
    nuevo en bucle no terminaría nunca): nuevo test con un servidor que sigue devolviendo 401
    tras el refresh confirma que `refreshToken()` se llama EXACTAMENTE una vez y que el 401
    final llega intacto al llamador.
  - Los nueve tests se rompieron a propósito, uno por uno, sobre una copia descartable del
    árbol (nunca en el repo): comentar cada llamada a `notifyInterceptorsOfFailure`, invertir
    el orden de `retriers`, invertir las dos ramas del `if let decision = ...`/`else` en
    `performWithRetry`, hacer que `.retry` ignore el `Retry-After` del servidor o el backoff, y
    quitar el `context.attempt == 1` de `TokenRefreshRetrier.retry` — cada mutación hizo fallar
    exactamente el test escrito para detectarla, y solo ese.

## [1.2.0] - 2026-09-04

### Seguridad

- **Trinquete de mutación 55 → 70**, con el score medido en **76,4 %** (120 mutantes muertos
  de 157) sobre el árbol que ya incluye la política de autenticación, la de redirecciones y
  el suelo de seguridad. Los supervivientes bajan de 39 a 19.

### Añadido

- `RequestAuthenticationPolicy` (`.automatic`/`.none`) en `BaseRequest`, surfaceado en
  `RequestContext.authenticationPolicy` para que CUALQUIER interceptor (no solo
  `BearerTokenInterceptor`) pueda consultarlo. Resuelve dos huecos reales de una app
  empresarial: hasta ahora no había forma de dejar un endpoint fuera de la autenticación
  automática (login, el propio refresh, un host de terceros recibían igualmente el
  `Authorization` interno) ni de que un `BaseRequest` fijara su propia credencial
  (`BearerTokenInterceptor` la pisaba sin condición). `.none` corta las DOS vías
  ambientales por las que una credencial le llega a un request sin que lo haya pedido:
  `BearerTokenInterceptor` no adjunta nada, y `buildURLRequest` retira, de
  `NetworkingConfiguration.defaultHeaders` (una API key o bearer fijo puesto una vez,
  globalmente — patrón normal, y exactamente lo que se filtraba en la primera versión de
  este cambio), los headers `Authorization`, `Proxy-Authorization`, `Cookie` y `X-Api-Key`
  (`APIService.ambientCredentialHeaderNames`, un conjunto exacto y deliberadamente
  estrecho — sin las coincidencias por subcadena de `HeaderRedactor`, pensadas para logs
  donde sobre-redactar es gratis, no para retirar headers de un request real). La vía
  EXPLÍCITA (`BaseRequest.headers`, la credencial que el propio endpoint declaró a
  propósito — un partner, otro tenant) nunca se toca, ni bajo `.automatic` (no se pisa) ni
  bajo `.none` (no se retira). La misma distinción decide, bajo `.automatic`, qué pisa
  `BearerTokenInterceptor`: un `Authorization` que llegó SOLO por `defaultHeaders` es
  ambiental (un diccionario estático que no puede llevar un token vivo) y el interceptor lo
  sustituye sin condición — es justo su trabajo suplirlo —, nunca uno que
  `BaseRequest.headers` declaró explícitamente. `RequestContext.explicitHeaderFields`
  (nuevo, `Set<String>` en minúsculas) es el canal que expone esa distinción a cualquier
  interceptor, no solo al de Bearer. Retrocompatible: el default `.automatic` reproduce el
  comportamiento de siempre para cualquier `BaseRequest` existente. Ver <doc:Authentication>
  para la tabla de precedencia de headers (antes no documentada en ningún sitio) y los
  casos de uso.
- `RedirectPolicy` (`Transport/RedirectPolicy.swift`) y su aplicación en
  `TaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`,
  configurable en `URLSessionTransport.init(redirectPolicy:)`. El agujero: `URLSession`
  sigue las redirecciones 3xx automáticamente y en silencio (no es un error, así que ningún
  `catch` del pipeline lo veía) y este paquete no fijaba ni comprobaba qué pasaba con
  `Authorization` cuando el destino cambiaba de origen. Medido empíricamente (nunca
  supuesto — `RedirectSecurityTests`, sockets loopback reales, ya que un `URLProtocol` de
  mock jamás invoca `willPerformHTTPRedirection`): Foundation retira
  `Authorization`/`Proxy-Authorization` de TODA redirección, incluida una de mismo
  origen — comportamiento no documentado y específico de CFNetwork, no garantizado en
  `swift-corelibs-foundation` (Linux) ni en otra versión de Darwin — pero no toca ningún
  otro header: `Cookie`, `X-Api-Key`, `X-Auth-Token` o una `Authentication` a medida cruzan
  a CUALQUIER destino sin filtrar, origen distinto incluido. Esa es la fuga real. Default
  seguro, `.followSanitizingCrossOrigin`: sigue la redirección; retira cualquier header con
  pinta de credencial cuando el origen (scheme/host/puerto) cambia, y restaura los que
  Foundation haya podido retirar por su cuenta cuando NO cambia (si no, una redirección
  legítima dentro del propio dominio perdería la sesión en silencio — una regresión
  funcional, no solo de seguridad). `.never` (no seguir ninguna redirección) y
  `.followPreservingAllHeaders` (opt-out explícito, sin filtrar nada) cubren el resto de
  casos de una app empresarial. El pinning se sigue aplicando tras una redirección a otro
  host sin cambio adicional — es un challenge por TAREA y el mismo `TaskDelegate` de la
  tarea sigue siendo su delegate; verificado en `RedirectSecurityTests`.
  `RedirectPolicy.sensitiveHeaderNames` es, deliberadamente, una segunda copia del conjunto
  exacto de `HeaderRedactor` (`Logging.swift`) — no la lista con coincidencias por
  subcadena, pensada para logs donde sobre-redactar es gratis, no para retirar headers de
  un request real (mismo criterio que `APIService.ambientCredentialHeaderNames`, añadido
  arriba para un problema relacionado pero distinto: credenciales ambientales de
  `defaultHeaders`, no redirecciones). Compartir una sola fuente para las tres listas queda
  como follow-up; `Logging.swift` estaba fuera del alcance de este cambio. Ver
  <doc:Transport> para la política completa y el comportamiento medido.
- `NetworkingConfiguration.enforceSecurityFloor(on:defaultResourceTimeout:)`: el suelo de
  seguridad ya no depende de partir de `defaultSessionConfiguration()`.
  `init(sessionConfiguration:)` acepta CUALQUIER fábrica, y una que solo quisiera tocar,
  por ejemplo, `timeoutIntervalForResource` podía escribir `{ URLSessionConfiguration.default }`
  y perder en silencio el TLS 1.2 mínimo — sin aviso, sin test. La nueva función sube (nunca
  baja) `tlsMinimumSupportedProtocolVersion` a TLS 1.2 y rellena `timeoutIntervalForResource`
  a 60 s cuando detecta el sentinel de "nadie lo tocó" (el default de Foundation son 604 800 s
  = 7 días, que además combina mal con `waitsForConnectivity = true`: un servidor que manda
  un byte cada 20 s mantiene la conexión viva DÍAS sin disparar nunca el timeout de
  inactividad de 30 s de `BaseRequest.timeout`). Cualquier valor explícito del consumidor
  (TLS 1.3, o un `timeoutIntervalForResource` propio para una descarga grande) se respeta tal
  cual — es un suelo, no un override. Deliberadamente NO toca cookies ni
  `waitsForConnectivity`: son preferencia legítima del consumidor (hay backends que
  autentican con cookies de sesión), no un mínimo de seguridad comparable a TLS.
  `defaultSessionConfiguration()` ahora delega en esta función (una sola fuente de verdad) y
  gana el mismo relleno de `timeoutIntervalForResource` — retrocompatible: nadie que la use
  nota nada salvo la mejora. Ver <doc:Transport>, sección "Suelo de seguridad de la sesión".

### Pruebas

- Mutation testing (`swift-mutation-testing`): 10 tests nuevos matan 15 de los supervivientes
  detectados sobre `main` (`APIErrorTests.swift`, `NetworkingConfigurationTests.swift`,
  `RetryBehaviorTests.swift`, `LoggingRedactionTests.swift`) — ninguno crea fichero paralelo,
  todos amplían una suite existente:
  - `APIError.isRetryable`: los dos casos degenerados que nadie construye en producción pero
    que el tipo no puede asumir que no ocurrirán — `.transport` sin `underlying` y
    `.httpStatus` sin `response` — ahora se afirman como NO reintentables explícitamente
    (antes, "sin datos" se comportaba como "reintentable" y nada lo notaba).
  - `APIError.description`: contrato completo (code/method/status/underlying resumido)
    afirmado carácter por carácter, incluyendo el caso mínimo (solo `code`, sin partes
    vacías) y un test de no-fuga dedicado — la URL, el body y el mensaje de `underlying`
    nunca deben sobrevivir en esta cadena log-safe.
  - `APIService.performWithRetry`: `maxAttempts` acota también la rama `catch let apiError
    as APIError` (cuando `buildURLRequest` falla, p. ej. `.encoding`, ANTES de que exista un
    `RequestContext`) — antes solo se probaba por el camino de `AttemptFailure`. El test usa
    un `RetryPolicy(shouldRetry:)` a medida que sí acepta `.encoding` (el predicado por
    defecto nunca lo haría) y cuenta los intentos reales de codificar el body. Conducir el
    `ManualClock` con una tarea en segundo plano (sin asumir cuántos backoffs habrá) evita que
    el test se cuelgue si una mutación del guard lanza antes de dormir nunca — verificado
    inyectando manualmente las mutaciones `<` → `<=` y la negación completa del guard contra
    una copia descartable del paquete: ambas fallan limpio (< 10 ms), ninguna cuelga.
  - `NetworkingConfiguration.defaultSessionConfiguration()`: los defaults documentados
    (`waitsForConnectivity`, cookies desactivadas, TLS 1.2 mínimo) se afirman por primera vez
    — antes solo se comprobaba que el punto de extensión compilaba. Se añade también el exit
    test que faltaba para la `precondition` real de `init` (mensaje incluido), con el mismo
    mecanismo que ya usaba `SSLPinningConfiguration`.
  - `LoggingInterceptor()`: los defaults `includeHeaders`/`includeBody` (`false`, opt-in) se
    verifican por `Mirror` — no hay otra forma de observarlos desde fuera sin interceptar
    `os.Logger` (descartado, ver el comentario de la suite) ni tocar producción para
    exponerlos; mismo mecanismo que `APIError.caseName` en este mismo target.
  - Supervivientes NO atacados, con justificación (ver informe de la tarea para el detalle):
    seis `NetLog.network.debug/error(...)` de `LoggingInterceptor` (ningún test de este
    target puede observar una llamada a `os.Logger`, documentado ya en la propia suite);
    `SSLPinningConfiguration.gatedForDevelopment`'s `#else` (código muerto en cualquier build
    DEBUG, que es como corre `swift test`); y el `>` → `>=` de `RetryPolicy.jitteredDelay`
    (mutante equivalente: mismo resultado observable para cualquier `Duration` no negativa).

## [1.1.0] - 2026-09-04

### Cambiado

- **Mutation testing enganchado al CI** (job `mutation`): la configuración
  `.swift-mutation-testing.yml` existía desde agosto pero nada la ejecutaba, y su umbral
  (60/80) nunca se había comprobado contra una medición real. Ahora corre por `schedule`
  semanal y por `workflow_dispatch` —no en cada push: cada mutante recompila y repite la
  suite, y la corrida completa son ~13 minutos— y sube el informe como artefacto. Los otros
  cuatro jobs llevan `if: github.event_name != 'schedule'` para que el disparo semanal no
  repita el CI entero.
- **El umbral pasa a ser un TRINQUETE medido, no un objetivo inventado**: 55, con el score
  real medido en 62,2 % (79 mutantes muertos de 127). El job falla si BAJA de ahí; se sube a
  mano cuando la suite mejore. La holgura de ~7 puntos es deliberada: el score depende de
  cuántos mutantes agotan el `timeout` y eso depende de la velocidad de la máquina, así que
  un trinquete clavado al valor exacto fallaría en un runner lento sin que nada hubiera
  empeorado.
- `Package.swift` y `Snippets/` se excluyen de la mutación: no son código de producción,
  ningún test los ejecuta, así que sus 10 mutantes sobrevivían siempre y diluían el score
  4,5 puntos.

### Añadido

- `NetworkingConfiguration.validateBaseURL(_:)` y `NetworkingConfiguration.BaseURLIssue`:
  valida `baseURL` (scheme + host) sin trapear — mismo patrón que
  `SSLPinningConfiguration.validatePins(_:)` — para cuando la URL venga de una fuente
  remota o no confiable (config remota, deep link) en vez de ser una constante de build.
  `init` sigue trapeando exactamente igual que antes (`precondition`, no `init throws`);
  ahora construye el mensaje del `precondition` a partir del mismo `BaseURLIssue`.

### Pruebas

- `LoggingInterceptor` (`RequestInterceptor.swift`) — el agujero de cobertura más sensible
  del paquete (14,6 % de líneas: prácticamente sin tests una pieza que decide qué sale a
  un sysdiagnose): su lógica de qué se logaría se extrae a cuatro funciones puras
  `internal` (`headersLogPayload`, `bodyLogPayload`, `failureLogFields`,
  `elapsedMilliseconds`) — `os.Logger` no se puede interceptar desde un test de SwiftPM
  (comprobado con `OSLogStore(scope: .currentProcessIdentifier)`: solo persiste entradas
  `.error`/`.fault`, nunca el nivel `.debug` que usan `willSend`/`didReceive`, justo donde
  viven headers y body) — y `LoggingRedactionTests.swift` verifica el contrato completo
  contra ellas: `HeaderRedactor` con todos los nombres/marcadores sensibles en cualquier
  capitalización y un header inocuo que NO se redacta; `includeHeaders` sin fuga jamás del
  valor de un `Authorization`; `didFail` sin exponer nunca `underlying` ni el body del
  servidor (estructuralmente, no solo por comportamiento); y el ciclo
  `willSend→didReceive/didFail` con el mismo `context.id`, en éxito y en fallo, contra el
  pipeline real. Cobertura de líneas: 14,6 % → 80,4 %.
- `Transport/TaskDelegate.swift` (44,6 % → 98,0 % de líneas, medido en local — la auditoría
  citaba 52,3 %, posiblemente antes del hotfix de hoy al gate de 2xx):
  `TaskDelegateTests.swift` cubre el progreso de subida/descarga
  (`didSendBodyData`/`didWriteData`/`didReceive(data:)`, incluido el caso
  `totalBytesExpected <= 0` y el clamp a `1.0`) y el gate de 2xx de
  `didFinishDownloadingTo` — un callback que `session.download(for:delegate:)` nunca
  invoca en el SDK que este paquete usa, así que ningún test end-to-end lo ejercitaba:
  éxito (mueve y sustituye), non-2xx (descarta el temporal sin tocar `destination`) y
  `fileMoveError`. Los dobles se obtienen con descargas/peticiones reales contra un
  servidor loopback (para conseguir una tarea con `.response` real) en vez de subclasear
  `URLSessionTask` — su único inicializador propio está deprecado desde macOS 10.15 y el
  paquete compila con warnings como errores.

## [1.0.1] - 2026-09-04

### Corregido

- `download(_:to:)`: un intento fallido ya no puede pisar ni borrar un fichero
  preexistente en `destination` que no hubiéramos escrito nosotros. Había dos fallos
  encadenados: (1) `HTTPTransport.download` (`URLSessionTransport` e `InMemoryTransport`)
  movía a `destination` el cuerpo de CUALQUIER respuesta, incluido un status de error
  (404, 500...) cuyo body es un mensaje de error del servidor, no el contenido pedido; (2)
  el `catch` de `APIService.download` borraba `destination` incondicionalmente al final,
  así que incluso un fichero ajeno que sobrevivía a (1) intacto (p. ej. porque falló por
  timeout antes de que el transporte llegara a tocar nada) se perdía igual. Pérdida de
  datos silenciosa, confirmada empíricamente: un fichero escrito en `destination` antes de
  llamar a `download` desaparecía si el primer (único) intento fallaba. Ahora el
  transporte solo mueve/escribe a `destination` en una respuesta 2xx — un status de error
  o un fallo de transporte deja `destination` completamente intacto, sin excepción — y
  `APIService.download` registra si `destination` existía antes del primer intento para
  no borrarlo nunca en el `catch` si ya estaba ahí. Un fichero preexistente ajeno
  sobrevive, contenido incluido, a un `download` fallido por cualquier motivo.

### Documentación

- Sección «App de referencia» en el README enlazando a
  [AppStarter](https://github.com/hiramvazquez/AppStarter), la app real que consume
  CoreNetworking y AppFoundation 1.0.x contra DummyJSON.
- Los 13 `@Snippet(path:)` de `Documentation.docc/` (no se resolvían en el primer
  `xcodebuild docbuild` sobre DerivedData limpio) se sustituyen por bloques de código en
  línea marcados `<!-- snippet: <name> -->`, verificados contra `Snippets/` por
  `Scripts/check-doc-snippets.sh` en CI (job `docs`, antes de `docbuild`).

## [1.0.0] - 2026-09-02

Primera versión estable.

### Roturas de API

- `APIError` pasa de ser un `enum` cerrado a un `struct` extensible con `Code` (conjunto
  abierto), `RequestSummary`, `ResponseSummary` y `underlying`. Añadir un `Code` nuevo ya
  no rompe a los consumidores. `TransportError` y `APIMessageError` desaparecen —
  `APIError.category` cubre la clasificación de alto nivel, y `decodeBody<T>(_:using:)`
  permite decodificar cualquier sobre de error del servidor con el tipo y el `JSONDecoder`
  del consumidor.
- `APIError` deja de ser `Equatable` (un `==` que ignorase `underlying` mentiría).
  `CoreNetworkingTestSupport` añade `APIError.stub(code:...)` para tests.
- `RetryPolicy.shouldRetry` pasa a `@Sendable (APIError, Int) -> Bool`; `RetryPolicy` deja
  de ser `Equatable` (el predicado es un closure).
- `RequestInterceptor.didFail(_:error:)` tipa `error: APIError` en vez de `Error`
  (sustituido más tarde por la firma con `RequestContext`, ver más abajo).
- `SSLPinningConfiguration`: `pinnedHosts: Set<String>?` → `hosts: Hosts` (`.all`/`.only`);
  `validateCertificateChain: Bool` → `chainValidation: ChainValidation`
  (`.system`/`.unsafeSkipForDevelopment`); el constructor exige ≥ 2 pines.
- `APIService.init` ya no crea su propia `URLSession`: el designado recibe
  `transport: any HTTPTransport` (el `convenience init(configuration:...)` de siempre se
  conserva).
- `RetryPolicy.initialDelay`/`.maxDelay` pasan de `TimeInterval` a `Duration`.
- `CoreNetworkingTestSupport.MockAPIService.result: Any?` desaparece —
  `stub(_:returning:)`/`stub(_:throwing:)` por tipo de request.
- `BaseRequest` se rediseña alrededor de `associatedtype Body: Encodable & Sendable =
  Never` / `associatedtype Response: Decodable & Sendable = Empty`; `parameters` se
  renombra a `body`; `timeoutInterval: TimeInterval` pasa a `timeout: Duration`;
  `headers`/`queryItems` dejan de ser opcionales.
- `HTTPMethod` cambia sus casos a minúscula (`.get`, `.post`, …) — `HTTPMethod.GET` ya no
  compila.
- `APIServiceProtocol.execute`: `execute<Request, Response: Decodable>(request:) ->
  Response` pasa a `execute<R: BaseRequest>(_:) -> R.Response`, con la sobrecarga
  `execute<R, Value>(_:as:)` añadida.
- `NetworkingConfiguration.environment` desaparece.
- `BaseResponse.swift` (`BaseResponse`, `EmptyResponse`), `RequestParameters`,
  `EmptyParameters`, `RequestValidationError`,
  `validated()`/`isValid`/`debugValidated()`/`requestDescription` se eliminan.
- `SessionDelegates.swift` (`PinningSessionDelegate`, `UploadProgressDelegate`)
  desaparece — el pinning decide por tarea con `TaskDelegate`.
- `APIServiceProtocol.download(request:progress:) -> Data` se sustituye por
  `data(for:progress:) -> Data` (en memoria) y `download(_:to:progress:)` (a disco).
- `RequestInterceptor` se reescribe alrededor de `RequestContext`: `willSend(_:context:)`
  pasa a `async throws(APIError)`; `didReceive` recibe `HTTPURLResponse` (no
  `URLResponse`) y `context`; `didFail` pasa a `didFail(_ error: APIError, context:)` (ya
  no recibe `request:` por separado).
- `APIService.init` (designado y `convenience`) gana `retriers: [any RequestRetrier] = []`.
- **`APIServiceProtocol.upload`** pasa a la misma forma que `execute`:
  `upload(_:data:progress:) -> Request.Response` (el tipo de respuesta ya no se anota en
  el call site, se infiere del propio request) más la sobrecarga
  `upload(_:data:as:progress:) -> Value`, igual que `execute(_:as:)`. Se elimina
  `upload(request:data:progress:) -> Response`. Migrar
  `service.upload(request: req, data: d)` a `service.upload(req, data: d)`.
- **`APIError.Category`** gana `.unreachable`
  (`networkConnectionLost`/`cannotConnectToHost`/`dnsLookupFailed`/`cannotFindHost`,
  antes indistinguibles de `.unknown`): un `switch` exhaustivo sobre `Category` en la app
  deja de compilar hasta añadir el caso — el propio doc del tipo pide comparar contra los
  casos conocidos y caer a `default`, nunca `switch` exhaustivo, precisamente por esto.
- `MockAPIService` (`CoreNetworkingTestSupport`) lanza `APIError(code: .unstubbed)` — no
  `.invalidResponse` — cuando un request no tiene stub registrado o el stub no coincide
  con el tipo pedido; `underlying` nombra el request y el tipo esperado. Un test que
  comparaba contra `.invalidResponse` para este caso debe comparar contra `.unstubbed`.

### Changed

- **`download(_:to:)`** pasa por el mismo `performWithRetry` que `execute`/`upload`/`data`
  — interceptores, `retriers` y `retryPolicy` incluidos — en vez de una copia paralela del
  pipeline de un único intento. Cada intento reescribe `destination` atómicamente, así que
  reintentar es válido: una descarga a medias reintenta desde cero, nunca reanuda. El
  mapeo de errores no cambia de comportamiento observable.
- `NetworkingConfiguration.protocolClasses` queda `@available(*, deprecated, message:
  "Configura protocolClasses en sessionConfiguration")` — sigue funcionando (se fusiona en
  la `URLSessionConfiguration` real), pero `sessionConfiguration` es ahora la única forma
  soportada de instalar un `URLProtocol` de mock.

### Added

- `HTTPTransport` (`Transport/HTTPTransport.swift`): el protocolo `send(_:progress:) async
  throws -> (Data, HTTPURLResponse)` que reemplaza al registro estático de `URLProtocol`
  como punto de inyección bajo `APIService`. `URLSessionTransport` es la implementación de
  producción: posee la `URLSession` y su `deinit`.
- `InMemoryTransport` (`CoreNetworkingTestSupport`): `HTTPTransport` en memoria, sin
  `URLSession` ni registro global — un `actor` por test. Soporta secuencias de respuestas
  (500 → 500 → 200).
- `ManualClock` (`CoreNetworkingTestSupport`): `Clock<Duration>` que solo avanza cuando el
  test llama a `advance(by:)`; `waitUntilSleeping()` suspende hasta que el pipeline
  registra el siguiente `sleep`.
- `MockURLProtocol` / `MockAPIHelper.setupMockSequence(...)`: soporte de secuencias también
  en el mock de integración.
- `Empty`: el `Decodable` que `BaseRequest.Response` usa por defecto y que `execute`
  produce para 204/205/body vacío.
- `NetworkingConfiguration.makeEncoder: @Sendable () -> JSONEncoder`.
- `NetworkingConfiguration.sessionConfiguration: @Sendable () -> URLSessionConfiguration`,
  con `defaultSessionConfiguration()` (`waitsForConnectivity`, cookies desactivadas, TLS
  1.2 mínimo) como valor por defecto.
- `PinningFailure` (`Transport/TaskDelegate.swift`), `public`: la señal interna que
  distingue "pinning rechazó el certificado" de "el llamador canceló".
  `CoreNetworkingTestSupport.InMemoryTransport.Outcome.pinningFailure(host:)` la expone en
  tests sin necesitar un handshake TLS real.
- `RequestRetrier` (`Retry/RequestRetrier.swift`): `func retry(_ error: APIError, context:
  RequestContext) async -> RetryDecision` (`.doNotRetry` / `.retry` /
  `.retryAfter(Duration)`), consultado ANTES que `RetryPolicy` en cada intento fallido.
- `Auth/TokenRefresher.swift`: `TokenRefreshing` (protocolo) y `actor TokenRefresher` —
  deduplica refreshes concurrentes. `BearerTokenInterceptor(tokenProvider:)` añade
  `Authorization: Bearer <token>` leyendo el token fresco en cada `willSend`.
  `TokenRefreshRetrier(refresher:)` refresca y reintenta un 401 solo en el primer intento.
- `CoreNetworkingTestSupport`: `RecordingInterceptor`, un `RequestInterceptor` público que
  graba `willSend`/`didReceive`/`didFail` en orden.
- `APIError.errorDescription` (`LocalizedError`): frase neutra y localizable
  (inglés/español, string catalog del paquete) por `category`, nunca un código pelado.
- `EndpointService` (`Sources/CoreNetworking/EndpointService.swift`): `public protocol
  EndpointService: Sendable { var api: any APIServiceProtocol { get } }` con `public
  extension EndpointService { func call<R: BaseRequest>(_ request: R) async
  throws(APIError) -> R.Response }`. Plantilla cómoda para un `Service` de un solo request
  — no un requisito: un `Service` que necesite más de un patrón de llamada sigue llamando
  `api.execute` directamente.
- `AGENTS.md` en la raíz del paquete: un Service por request, mapeo de errores con
  `category`/`decodeBody`, cómo testear con `MockAPIService`/`InMemoryTransport`.
- `Empty` conforma `Equatable`.
- `APIError.Code.unstubbed` (`CoreNetworkingTestSupport`): el código que lanza
  `MockAPIService` sin stub.
- `errorDescription` (EN/ES, `Localizable.xcstrings`) para `.unreachable`: "Could not
  connect to the server." / "No se pudo conectar con el servidor.".

### Fixed

- Ningún `catch` del pipeline pierde ya el error original: un `NSError` arbitrario del
  transporte llega como `code == .unexpected` con `underlying` intacto; un fallo de
  decodificación conserva el body de la respuesta para diagnóstico.
- 401 y 403 ya no colapsan en la misma categoría (`.unauthorized` vs. `.forbidden`).
- `isRetryable` ya no reintenta `notConnectedToInternet` y sí reintenta `dnsLookupFailed` /
  `cannotFindHost`, que son transitorios.
- `execute` ya soporta respuestas vacías: `Response == Empty` decodifica a `Empty()` sin
  mirar el body (204, HEAD, DELETE); un `Response` declarado que no sea `Empty` con body
  vacío lanza `.decoding` con `response.body.isEmpty` en vez de que `JSONDecoder` falle con
  un mensaje opaco.
- `Content-Type: application/json` ya solo se envía cuando el request declara `body`
  (antes viajaba también en GET sin cuerpo); `Accept: application/json` se envía siempre,
  sobrescribible por `headers`.
- El body del request se codifica con `NetworkingConfiguration.makeEncoder` en vez de un
  `JSONEncoder()` recién instanciado.
- `buildURLRequest` usa `URL.appending(path:)` en vez de `appendingPathComponent`.

### Docs

- `RequestSummary.init(URLRequest)` documenta que un método fuera del `HTTPMethod`
  cerrado (p. ej. WebDAV) se guarda como `.get` igual que `httpMethod == nil` —
  limitación conocida, no un bug; `HTTPMethod` sigue cerrado a propósito (sin `case
  custom(String)`).
- Tabla ASN.1 de SPKI: añadido RSA-3072 (antes solo RSA-2048/4096 y EC P-256/P-384).
