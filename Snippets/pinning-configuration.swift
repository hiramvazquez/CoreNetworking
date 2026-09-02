// SSL pinning con pin de respaldo (RFC 7469 §2.5): sin él, rotar la clave del
// servidor deja cada copia instalada de la app sin poder conectar.
import CoreNetworking
import Foundation

let pinning = SSLPinningConfiguration(
    publicKeyHashes: [
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",  // clave actual
        "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys=",  // pin de respaldo
    ],
    hosts: .only(["api.miapp.com"])
)

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
let service = APIService(configuration: configuration, sslPinning: pinning)
