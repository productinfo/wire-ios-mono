//
// Wire
// Copyright (C) 2023 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation

private let zmLog = ZMSLog(tag: "terminate federation")

@objcMembers
public final class TerminateFederationRequestStrategy: AbstractRequestStrategy {

    // MARK: - Properties

    var federationTerminationManager: FederationTerminationManagerInterface

    // MARK: - Life cycle

    public override init(
        withManagedObjectContext managedObjectContext: NSManagedObjectContext,
        applicationStatus: ApplicationStatus
    ) {
        federationTerminationManager = FederationTerminationManager(with: managedObjectContext)

        super.init(
            withManagedObjectContext: managedObjectContext,
            applicationStatus: applicationStatus
        )

        configuration = [
            .allowsRequestsWhileOnline,
            .allowsRequestsDuringQuickSync,
            .allowsRequestsWhileWaitingForWebsocket,
            .allowsRequestsWhileInBackground
        ]
    }

    // MARK: - Request

    public override func nextRequestIfAllowed(for apiVersion: APIVersion) -> ZMTransportRequest? {
        return nil
    }

}

// MARK: - Event processing

extension TerminateFederationRequestStrategy: ZMEventConsumer {

    public func processEvents(
        _ events: [ZMUpdateEvent],
        liveEvents: Bool,
        prefetchResult: ZMFetchRequestBatchResult?
    ) {
        events.forEach(processEvent)
    }

    private func processEvent(_ event: ZMUpdateEvent) {

        switch event.type {
        case .federationDelete:
            if let payload = event.eventPayload(type: Payload.FederationDelete.self) {
                federationTerminationManager.handleFederationTerminationWith(payload.domain)
            }

        case .federationConnectionRemoved:
            if let payload = event.eventPayload(type: Payload.ConnectionRemoved.self),
               payload.domains.count == 2,
               let firstDomain = payload.domains.first,
               let secondDomain = payload.domains.last {
                federationTerminationManager.handleFederationTerminationBetween(firstDomain,
                                                                                otherDomain: secondDomain)
            }

        default:
            break

        }
    }

}

extension Payload {

    /// The domain that the self domain has stopped federate with.
    struct FederationDelete: Codable {

        let domain: String
        let type: String

    }

    /// The list of domains that have terminated federation with each other.
    struct ConnectionRemoved: Codable {

        let domains: [String]
        let type: String

    }

}
