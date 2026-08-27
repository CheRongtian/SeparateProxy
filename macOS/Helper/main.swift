import Foundation
import SeparateProxyCore

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let identity = CodeSigningIdentity.current(),
        let appIdentifier = SeparateProxyIdentifiers.appBundleIdentifier(
            forHelperIdentifier: identity.identifier
        ),
        let requirement = CodeSigningRequirementBuilder.requirement(
            identifier: appIdentifier,
            teamIdentifier: identity.teamIdentifier
        ) else {
            return false
        }

        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(
            with: SeparateProxyHelperProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: SeparateProxyIdentifiers.helper)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
