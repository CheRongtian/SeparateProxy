import Foundation
import SeparateProxyCore

enum HelperClientError: LocalizedError {
    case signingTeamUnavailable
    case connectionUnavailable
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .signingTeamUnavailable:
            return "The Apple Development signing team is not configured."
        case .connectionUnavailable:
            return "The privileged helper is unavailable."
        case .invalidReply:
            return "The privileged helper returned an invalid response."
        }
    }
}

final class HelperClient {
    private var connection: NSXPCConnection?

    func status(completion: @escaping (Result<NSDictionary, Error>) -> Void) {
        withProxy(completion: completion) { proxy in
            proxy.status { completion(.success($0)) }
        }
    }

    func start(
        accessKey: String,
        chromeBundlePath: String,
        completion: @escaping (Result<NSDictionary, Error>) -> Void
    ) {
        withProxy(completion: completion) { proxy in
            proxy.startProxy(
                accessKey: accessKey,
                chromeBundlePath: chromeBundlePath
            ) { completion(.success($0)) }
        }
    }

    func stop(completion: @escaping (Result<NSDictionary, Error>) -> Void) {
        withProxy(completion: completion) { proxy in
            proxy.stopProxy { completion(.success($0)) }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func withProxy(
        completion: @escaping (Result<NSDictionary, Error>) -> Void,
        operation: (SeparateProxyHelperProtocol) -> Void
    ) {
        do {
            let connection = try activeConnection()
            let proxyObject = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.invalidate()
                completion(.failure(error))
            }
            guard let proxy = proxyObject as? SeparateProxyHelperProtocol else {
                throw HelperClientError.connectionUnavailable
            }
            operation(proxy)
        } catch {
            completion(.failure(error))
        }
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let connection {
            return connection
        }

        guard let identity = CodeSigningIdentity.current(),
        let requirement = CodeSigningRequirementBuilder.requirement(
            identifier: SeparateProxyIdentifiers.helperBundleIdentifier(
                forAppIdentifier: identity.identifier
            ),
            teamIdentifier: identity.teamIdentifier
        ) else {
            throw HelperClientError.signingTeamUnavailable
        }

        let newConnection = NSXPCConnection(
            machServiceName: SeparateProxyIdentifiers.helper,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: SeparateProxyHelperProtocol.self
        )
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.connection = nil
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }
}
