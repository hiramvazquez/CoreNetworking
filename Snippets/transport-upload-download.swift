// upload/data/download comparten pipeline con execute — interceptores, retry y
// mapeo de errores incluidos. download(_:to:) escribe directo a disco, nunca
// mantiene el body completo en memoria.
import CoreNetworking
import Foundation

struct UploadAvatar: BaseRequest {
    struct Response: Decodable, Sendable { let url: String }
    let path = "/avatar"
    let method = HTTPMethod.post
}

struct DownloadReport: BaseRequest {
    let path = "/reports/latest.pdf"
    let method = HTTPMethod.get
}

func uploadAndDownload(service: any APIServiceProtocol, avatarData: Data, destination: URL) async throws(APIError) {
    let uploaded = try await service.upload(UploadAvatar(), data: avatarData) { fraction in
        print("subida: \(fraction)")
    }
    print(uploaded.url)

    try await service.download(DownloadReport(), to: destination) { fraction in
        print("descarga: \(fraction)")
    }
}
