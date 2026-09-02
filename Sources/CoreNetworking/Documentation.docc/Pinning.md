# SSL Pinning

`SSLPinningConfiguration`: pinning de clave pública (SPKI SHA-256), decisión de 3 estados,
pin de respaldo obligatorio.

## Overview

### Qué recibe la app cuando falla el pinning

`APIError(code: .untrustedServer, category: .untrustedServer)` — nunca `.cancelled`. Un
delegate **por tarea** (uno nuevo por cada `execute`/`upload`/`data`/`download`, no uno
compartido a nivel de sesión) decide el challenge de server-trust; si cancela por pinning,
lo recuerda para que el transporte traduzca el `URLError(.cancelled)` resultante a un error
interno del transporte, que `APIService` mapea a `.untrustedServer`. Una cancelación real
del `Task` nunca activa ese camino, así que sigue llegando como `.cancelled`:

```swift
switch error.category {
case .untrustedServer: showInsecureConnection()   // MITM: nunca se ignora como cancelación
case .cancelled: return                            // cancelación real del Task
default: show(error.localizedDescription)
}
```

### Pin = SHA-256 del SPKI

Mismo formato que TrustKit, HPKP y `NSPinnedDomains`:

```bash
openssl s_client -connect api.miapp.com:443 < /dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | base64
```

RFC 7469 §2.5 exige un **pin de respaldo**: una clave que ya tienes pero que el servidor
todavía no sirve. Sin él, rotar la clave del servidor deja cada copia instalada de la app
sin poder conectar hasta la próxima actualización — ver <doc:Recipes> para el
procedimiento de rotación completo.

<!-- snippet: pinning-configuration -->
```swift
import CoreNetworking
import Foundation

let pinning = SSLPinningConfiguration(
    publicKeyHashes: [
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",  // clave actual
        "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys="  // pin de respaldo
    ],
    hosts: .only(["api.miapp.com"])
)

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
let service = APIService(configuration: configuration, sslPinning: pinning)
```

El constructor exige, con `precondition`, al menos 2 pines válidos. Si los pines vienen de
una fuente remota o no confiable, valida primero con
``SSLPinningConfiguration/validatePins(_:)`` para convertir un payload malformado en un
error manejado en vez de un crash.

Decisión de 3 estados: host sin pin → validación TLS por defecto del sistema; pin válido →
continúa; pin inválido o cadena rota → conexión cancelada. `.disabled` equivale a "sin
pinning" (el sistema valida normal; nunca acepta a ciegas). `chainValidation:
.unsafeSkipForDevelopment` salta la validación de cadena para certificados autofirmados;
solo tiene efecto en `DEBUG` — en Release degrada a `.system` con un `assertionFailure`.

Tabla ASN.1 de SPKI soportada: RSA-2048/3072/4096, EC P-256/P-384.

### Pinning declarativo: `NSPinnedDomains`

Para pines estáticos, Apple ofrece pinning declarativo desde iOS 14 —
`NSAppTransportSecurity` → `NSPinnedDomains` en el `Info.plist` — sin escribir código, sin
delegate propio, y cubriendo TODA `URLSession` del proceso (no solo la de este paquete):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSPinnedDomains</key>
    <dict>
        <key>api.miapp.com</key>
        <dict>
            <key>NSIncludesSubdomains</key><true/>
            <key>NSPinnedLeafIdentities</key>
            <array>
                <dict><key>SPKI-SHA256-BASE64</key><string>r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=</string></dict>
                <dict><key>SPKI-SHA256-BASE64</key><string>Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys=</string></dict>
            </array>
        </dict>
    </dict>
</dict>
```

Usa el pinning programático de este paquete cuando necesites pines que se obtienen o
rotan en remoto, o un conjunto de hosts decidido en tiempo de ejecución — lo que un plist
estático no puede expresar. `NSPinnedDomains` no cubre `WKWebView`.

## Topics

- ``SSLPinningConfiguration``
- ``SSLPinningConfiguration/Hosts``
- ``SSLPinningConfiguration/ChainValidation``
- ``SSLPinningConfiguration/PinIssue``
- ``PinningValidationResult``
