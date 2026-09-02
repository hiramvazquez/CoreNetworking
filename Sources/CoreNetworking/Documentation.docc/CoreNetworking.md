# ``CoreNetworking``

Capa de red standalone sobre `URLSession`: async/await, errores tipados, retry seguro,
SSL pinning. Sin dependencias externas.

## Overview

Toda la API pública lanza `throws(APIError)` — un único tipo de error que conserva lo que
se pidió, lo que dijo el servidor y el error de debajo, y se clasifica con `category` para
que la app decida sin castear. La configuración (`NetworkingConfiguration`) entra siempre
por `init`: sin singletons, sin fallback implícito. El retry es seguro por defecto (solo
métodos idempotentes, backoff con jitter, `Retry-After` respetado) y el pinning SSL es de
clave pública (SPKI SHA-256) con decisión de 3 estados. Los mocks (`MockAPIService`,
`InMemoryTransport`) viven en un producto separado, `CoreNetworkingTestSupport`, que nunca
viaja en el binario de producción.

En la arquitectura View → ViewModel → Logic → Services/Stores de AppFoundation, este
paquete lo toca un único `Service` por `EndpointService`/`api.execute` — ver <doc:Architecture>.

## Topics

### Empieza aquí

- <doc:GettingStarted>

### Peticiones

- <doc:Requests>

### Errores

- <doc:ErrorHandling>

### Reintentos

- <doc:Retry>

### SSL Pinning

- <doc:Pinning>

### Interceptores y autenticación

- <doc:Interceptors>
- <doc:Authentication>

### Transporte

- <doc:Transport>

### Arquitectura, recetas y testing

- <doc:Architecture>
- <doc:Recipes>
- <doc:Testing>
- <doc:FAQ>
