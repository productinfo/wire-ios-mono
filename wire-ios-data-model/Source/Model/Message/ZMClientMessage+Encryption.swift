//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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
import WireCryptobox

private var zmLog = ZMSLog(tag: "message encryption")

public let ZMFailedToCreateEncryptedMessagePayloadString = "💣"

// MARK: - Encrypted data for recipients

public protocol EncryptedPayloadGenerator {

    typealias Payload = (data: Data, strategy: MissingClientsStrategy)

    /// Produces a payload with encrypted data and the strategy to use to handle missing clients.

    func encryptForTransport() -> Payload?

    /// Produces a payload with encrypted data and the strategy to use to handle missing clients.
    /// This variant creates a payload with qualified idenitifier suitable for federated requests.

    func encryptForTransportQualified() -> Payload?

    var debugInfo: String { get }

}

/// Strategy for handling missing clients.
///
/// When sending a message through the backend, the backend might warn us that some user clients that
/// were supposed to be there are missing (e.g. another user added a new client that we don't yet know about).
/// The various strategies give a hint to the backend of how we want to handle missing clients.

public enum MissingClientsStrategy: Equatable {

    /// Fail the request if there is any missing client.

    case doNotIgnoreAnyMissingClient

    /// Fail the request if there is any missing client for the given user, but ignore missing clients of
    /// any other user.

    case ignoreAllMissingClientsNotFromUsers(users: Set<ZMUser>)

    /// Do not fail the request, no matter which clients are missing.

    case ignoreAllMissingClients

}

// FUTUREWORK: remove this code duplication (it's duplicated on ZMAssetClientMessage)
extension ZMClientMessage {

    func updateUnderlayingMessageBeforeSending(in context: NSManagedObjectContext) {
        if conversation?.conversationType == .oneOnOne {
            // Update expectsReadReceipt flag to reflect the current user setting
            if var updatedGenericMessage = underlyingMessage {
                updatedGenericMessage.setExpectsReadConfirmation(ZMUser.selfUser(in: context).readReceiptsEnabled)
                do {
                    try setUnderlyingMessage(updatedGenericMessage)
                } catch {
                    Logging.messageProcessing.warn("Failed to update generic message. Reason: \(error.localizedDescription)")
                }
            }
        }

        if let legalHoldStatus = conversation?.legalHoldStatus {
            // Update the legalHoldStatus flag to reflect the current known legal hold status
            if var updatedGenericMessage = underlyingMessage {
                updatedGenericMessage.setLegalHoldStatus(legalHoldStatus.denotesEnabledComplianceDevice ? .enabled : .disabled)
                do {
                    try setUnderlyingMessage(updatedGenericMessage)
                } catch {
                    Logging.messageProcessing.warn("Failed to update generic message. Reason: \(error.localizedDescription)")
                }
            }
        }
    }

}

extension ZMAssetClientMessage {

    func updateUnderlayingMessageBeforeSending(in context: NSManagedObjectContext) {
        if conversation?.conversationType == .oneOnOne {
            // Update expectsReadReceipt flag to reflect the current user setting
            if var updatedGenericMessage = underlyingMessage {
                updatedGenericMessage.setExpectsReadConfirmation(ZMUser.selfUser(in: context).readReceiptsEnabled)
                do {
                    try setUnderlyingMessage(updatedGenericMessage)
                } catch {
                    Logging.messageProcessing.warn("Failed to update generic message. Reason: \(error.localizedDescription)")
                }
            }
        }

        if let legalHoldStatus = conversation?.legalHoldStatus {
            // Update the legalHoldStatus flag to reflect the current known legal hold status
            if var updatedGenericMessage = underlyingMessage {
                updatedGenericMessage.setLegalHoldStatus(legalHoldStatus.denotesEnabledComplianceDevice ? .enabled : .disabled)
                do {
                    try setUnderlyingMessage(updatedGenericMessage)
                } catch {
                    Logging.messageProcessing.warn("Failed to update generic message. Reason: \(error.localizedDescription)")
                }
            }
        }
    }

}

// MARK: - Proteus

extension ZMClientMessage: EncryptedPayloadGenerator {

    public func encryptForTransport() -> Payload? {
        guard
            let conversation = conversation,
            let context = managedObjectContext
        else {
            return nil
        }

        updateUnderlayingMessageBeforeSending(in: context)
        return underlyingMessage?.encryptForTransport(for: conversation)
    }

    public func encryptForTransportQualified() -> Payload? {
        guard
            let conversation = conversation,
            let context = managedObjectContext
        else {
            return nil
        }

        updateUnderlayingMessageBeforeSending(in: context)
        return underlyingMessage?.encryptForTransport(for: conversation, useQualifiedIdentifiers: true)
    }

    public var debugInfo: String {
        return underlyingMessage?.safeForLoggingDescription ?? ""
    }

}

extension ZMAssetClientMessage: EncryptedPayloadGenerator {

    public func encryptForTransport() -> Payload? {
        guard
            let conversation = conversation,
            let context = managedObjectContext
        else {
            return nil
        }

        updateUnderlayingMessageBeforeSending(in: context)
        return underlyingMessage?.encryptForTransport(for: conversation)
    }

    public func encryptForTransportQualified() -> Payload? {
        guard
            let conversation = conversation,
            let context = managedObjectContext
        else {
            return nil
        }

        updateUnderlayingMessageBeforeSending(in: context)
        return underlyingMessage?.encryptForTransport(for: conversation, useQualifiedIdentifiers: true)
    }

    public var debugInfo: String {
        return "\(String(describing: underlyingMessage))"
    }

}

extension GenericMessage {

    public func encryptForProteus(for recipients: [ZMUser: Set<UserClient>],
                                  with missingClientsStrategy: MissingClientsStrategy,
                                  externalData: Data? = nil,
                                  in context: NSManagedObjectContext) {

    }

}

extension GenericMessage {

    private typealias EncryptionFunction = (ProteusSessionID, Data) throws -> Data?

    /// Attempts to generate an encrypted payload for recipients in the given conversation.

    public func encryptForTransport(
        for conversation: ZMConversation,
        useQualifiedIdentifiers: Bool = false,
        externalData: Data? = nil
    ) -> EncryptedPayloadGenerator.Payload? {
        guard let context = conversation.managedObjectContext else {
            return nil
        }

        let selfUser = ZMUser.selfUser(in: context)
        let (users, missingClientsStrategy) = recipientUsersForMessage(in: conversation, selfUser: selfUser)
        let recipients = users.mapToDictionary { $0.clients }

        var encryptedData: Data?

        context.proteusProvider.perform(
            withProteusService: { proteusService in
                encryptedData = encrypt(
                    using: proteusService,
                    for: recipients,
                    with: missingClientsStrategy,
                    externalData: externalData,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            },
            withKeyStore: { keyStore in
                encryptedData = legacyEncrypt(
                    using: keyStore,
                    for: recipients,
                    with: missingClientsStrategy,
                    externalData: externalData,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            }
        )

        guard let encryptedData = encryptedData else {
            return nil
        }

        return (encryptedData, missingClientsStrategy)
    }

    /// Attempts to generate an encrypted payload for the given set of users.

    public func encryptForTransport(
        forBroadcastRecipients recipients: Set<ZMUser>,
        useQualifiedIdentifiers: Bool = false,
        in context: NSManagedObjectContext
    ) -> EncryptedPayloadGenerator.Payload? {
        // It's important to ignore all irrelevant missing clients, because otherwise the backend will enforce that
        // the message is sent to all team members and contacts.
        let missingClientsStrategy = MissingClientsStrategy.ignoreAllMissingClientsNotFromUsers(users: recipients)

        let messageRecipients = recipients.mapToDictionary { $0.clients }
        var encryptedData: Data?

        context.proteusProvider.perform(
            withProteusService: { proteusService in
                encryptedData = encrypt(
                    using: proteusService,
                    for: messageRecipients,
                    with: missingClientsStrategy,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            },
            withKeyStore: { keyStore in
                encryptedData = legacyEncrypt(
                    using: keyStore,
                    for: messageRecipients,
                    with: missingClientsStrategy,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            }
        )

        guard let encryptedData = encryptedData else {
            return nil
        }

        return (encryptedData, missingClientsStrategy)
    }

    /// Attempts to generate an encrypted payload for the given collection of user clients.

    public func encryptForTransport(
        for recipients: [ZMUser: Set<UserClient>],
        useQualifiedIdentifiers: Bool = false,
        in context: NSManagedObjectContext
    ) -> EncryptedPayloadGenerator.Payload? {
        // We're targeting a specific client so we want to ignore all missing clients.
        let missingClientsStrategy = MissingClientsStrategy.ignoreAllMissingClients
        var encryptedData: Data?

        context.proteusProvider.perform(
            withProteusService: { proteusService in
                encryptedData = encrypt(
                    using: proteusService,
                    for: recipients,
                    with: missingClientsStrategy,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            },
            withKeyStore: { keyStore in
                encryptedData = legacyEncrypt(
                    using: keyStore,
                    for: recipients,
                    with: missingClientsStrategy,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            }
        )

        guard let encryptedData = encryptedData else {
            return nil
        }

        return (encryptedData, missingClientsStrategy)
    }

    private func encrypt(
        using proteusService: ProteusServiceInterface,
        for recipients: [ZMUser: Set<UserClient>],
        with missingClientsStrategy: MissingClientsStrategy,
        externalData: Data? = nil,
        useQualifiedIdentifiers: Bool = false,
        in context: NSManagedObjectContext
    ) -> Data? {
        guard
            let selfClient = ZMUser.selfUser(in: context).selfClient(),
            selfClient.remoteIdentifier != nil
        else {
            return nil
        }

        var messageData: Data?

        // TODO: get core crypto file lock

        if useQualifiedIdentifiers, let selfDomain = ZMUser.selfUser(in: context).domain {
            let message = proteusMessage(
                selfClient,
                selfDomain: selfDomain,
                recipients: recipients,
                missingClientsStrategy: missingClientsStrategy,
                externalData: externalData
            ) { sessionID, plainText in
                try proteusService.encrypt(
                    data: plainText,
                    forSession: sessionID
                )
            }

            messageData = try? message.serializedData()

        } else {
            let message = otrMessage(
                selfClient,
                recipients: recipients,
                missingClientsStrategy: missingClientsStrategy,
                externalData: externalData
            ) { sessionID, plainText in
                try proteusService.encrypt(
                    data: plainText,
                    forSession: sessionID
                )
            }

            messageData = try? message.serializedData()
        }

        // Message too big?
        if let data = messageData, UInt(data.count) > ZMClientMessage.byteSizeExternalThreshold && externalData == nil {
            // The payload is too big, we therefore rollback the session since we won't use the message we just encrypted.
            // This will prevent us advancing sender chain multiple time before sending a message, and reduce the risk of TooDistantFuture.
            messageData = self.encryptForTransportWithExternalDataBlob(
                for: recipients,
                with: missingClientsStrategy,
                useQualifiedIdentifiers: useQualifiedIdentifiers,
                in: context
            )
        }

        // Reset all failed sessions.
        recipients.values
            .flatMap { $0 }
            .forEach { $0.failedToEstablishSession = false }

        return messageData
    }

    private func legacyEncrypt(
        using keyStore: UserClientKeysStore,
        for recipients: [ZMUser: Set<UserClient>],
        with missingClientsStrategy: MissingClientsStrategy,
        externalData: Data? = nil,
        useQualifiedIdentifiers: Bool = false,
        in context: NSManagedObjectContext
    ) -> Data? {
        guard
            let selfClient = ZMUser.selfUser(in: context).selfClient(),
            selfClient.remoteIdentifier != nil
        else {
            return nil
        }

        var messageData: Data?

        keyStore.encryptionContext.perform { sessionsDirectory in
            if useQualifiedIdentifiers, let selfDomain = ZMUser.selfUser(in: context).domain {
                let message = proteusMessage(
                    selfClient,
                    selfDomain: selfDomain,
                    recipients: recipients,
                    missingClientsStrategy: missingClientsStrategy,
                    externalData: externalData
                ) { sessionID, plainText in
                    try sessionsDirectory.encryptCaching(
                        plainText,
                        for: sessionID.mapToEncryptionSessionID()
                    )
                }

                messageData = try? message.serializedData()

            } else {
                let message = otrMessage(
                    selfClient,
                    recipients: recipients,
                    missingClientsStrategy: missingClientsStrategy,
                    externalData: externalData
                ) { sessionID, plainText in
                    try sessionsDirectory.encryptCaching(
                        plainText,
                        for: sessionID.mapToEncryptionSessionID()
                    )
                }

                messageData = try? message.serializedData()
            }

            // Message too big?
            if let data = messageData, UInt(data.count) > ZMClientMessage.byteSizeExternalThreshold && externalData == nil {
                // The payload is too big, we therefore rollback the session since we won't use the message we just encrypted.
                // This will prevent us advancing sender chain multiple time before sending a message, and reduce the risk of TooDistantFuture.
                sessionsDirectory.discardCache()
                messageData = self.encryptForTransportWithExternalDataBlob(
                    for: recipients,
                    with: missingClientsStrategy,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            }
        }

        // Reset all failed sessions.
        recipients.values
            .flatMap { $0 }
            .forEach { $0.failedToEstablishSession = false }

        return messageData
    }

    private func proteusMessage(
        _ selfClient: UserClient,
        selfDomain: String,
        recipients: [ZMUser: Set<UserClient>],
        missingClientsStrategy: MissingClientsStrategy,
        externalData: Data?,
        using encryptionFunction: EncryptionFunction
    ) -> Proteus_QualifiedNewOtrMessage {
        let qualifiedUserEntries = qualifiedUserEntriesWithEncryptedData(
            selfClient,
            selfDomain: selfDomain,
            recipients: recipients,
            using: encryptionFunction
        )

        // We do not want to send pushes for delivery receipts.
        let nativePush = !hasConfirmation

        return Proteus_QualifiedNewOtrMessage(
            withSender: selfClient,
            nativePush: nativePush,
            recipients: qualifiedUserEntries,
            missingClientsStrategy: missingClientsStrategy,
            blob: externalData
        )
    }

    /// Returns a message for the given recipients.

    private func otrMessage(
        _ selfClient: UserClient,
        recipients: [ZMUser: Set<UserClient>],
        missingClientsStrategy: MissingClientsStrategy,
        externalData: Data?,
        using encryptionFunction: EncryptionFunction
    ) -> Proteus_NewOtrMessage {
        let userEntries = userEntriesWithEncryptedData(
            selfClient,
            recipients: recipients,
            using: encryptionFunction
        )

        // We do not want to send pushes for delivery receipts.
        let nativePush = !hasConfirmation

        var message = Proteus_NewOtrMessage(
            withSender: selfClient,
            nativePush: nativePush,
            recipients: userEntries,
            blob: externalData
        )

        if case .ignoreAllMissingClientsNotFromUsers(let users) = missingClientsStrategy {
            message.reportMissing = Array(users.map { $0.userId })
        }

        return message
    }

    private func qualifiedUserEntriesWithEncryptedData(
        _ selfClient: UserClient,
        selfDomain: String,
        recipients: [ZMUser: Set<UserClient>],
        using encryptionFunction: EncryptionFunction
    ) -> [Proteus_QualifiedUserEntry] {
        let recipientsByDomain = Dictionary(grouping: recipients) { (element) -> String in
            element.key.domain ?? selfDomain
        }

        return recipientsByDomain.compactMap { domain, recipients in
            let userEntries: [Proteus_UserEntry] = recipients.compactMap { (user, clients) in
                guard !user.isAccountDeleted else { return nil }

                let clientEntries = clientEntriesWithEncryptedData(
                    selfClient,
                    userClients: clients,
                    using: encryptionFunction
                )

                guard !clientEntries.isEmpty else { return nil }
                return Proteus_UserEntry(withUser: user, clientEntries: clientEntries)
            }

            return Proteus_QualifiedUserEntry(withDomain: domain, userEntries: userEntries)
        }
    }

    private func userEntriesWithEncryptedData(
        _ selfClient: UserClient,
        recipients: [ZMUser: Set<UserClient>],
        using encryptionFunction: EncryptionFunction
    ) -> [Proteus_UserEntry] {
        return recipients.compactMap { (user, clients) in
            guard !user.isAccountDeleted else { return nil }

            let clientEntries = clientEntriesWithEncryptedData(
                selfClient,
                userClients: clients,
                using: encryptionFunction
            )

            guard !clientEntries.isEmpty else { return nil }

            return Proteus_UserEntry(withUser: user, clientEntries: clientEntries)
        }
    }

    private func clientEntriesWithEncryptedData(
        _ selfClient: UserClient,
        userClients: Set<UserClient>,
        using encryptionFunction: EncryptionFunction
    ) -> [Proteus_ClientEntry] {
        return userClients.compactMap { client in
            guard client != selfClient else { return nil }
            return clientEntry(for: client, using: encryptionFunction)
        }
    }

    // Assumes it's not the self client.
    private func clientEntry(
        for client: UserClient,
        using encryptionFunction: EncryptionFunction
    ) -> Proteus_ClientEntry? {
        guard let sessionID = client.proteusSessionID else {
            return nil
        }

        guard !client.failedToEstablishSession else {
            // If the session is corrupted, we will send a special payload.
            let data = ZMFailedToCreateEncryptedMessagePayloadString.data(using: String.Encoding.utf8)!
            WireLogger.proteus.error("Failed to encrypt payload: session is not established with client: \(client.remoteIdentifier)", attributes: nil)
            return Proteus_ClientEntry(withClient: client, data: data)
        }

        do {
            let plainText = try serializedData()
            let encryptedData = try encryptionFunction(sessionID, plainText)
            guard let data = encryptedData else { return nil }
            return Proteus_ClientEntry(withClient: client, data: data)
        } catch {
            WireLogger.proteus.error("failed to encrypt payload for a client: \(String(describing: error))")
            return nil
        }
    }

    func recipientUsersForMessage(in conversation: ZMConversation, selfUser: ZMUser) -> (users: Set<ZMUser>, strategy: MissingClientsStrategy) {
        let (services, otherUsers) = conversation.localParticipants.categorizeServicesAndUser()

        func recipientForButtonActionMessage() -> Set<ZMUser> {
            guard
                case .buttonAction? = content,
                let managedObjectContext = conversation.managedObjectContext,
                let message = ZMMessage.fetch(withNonce: UUID(uuidString: buttonAction.referenceMessageID), for: conversation, in: managedObjectContext),
                let sender = message.sender
            else {
                fatal("buttonAction needs a recipient")
            }

            return Set(arrayLiteral: sender)
        }

        func recipientForConfirmationMessage() -> Set<ZMUser>? {
            guard
                hasConfirmation,
                let managedObjectContext = conversation.managedObjectContext,
                let message = ZMMessage.fetch(withNonce: UUID(uuidString: confirmation.firstMessageID), for: conversation, in: managedObjectContext),
                let sender = message.sender
                else {
                    return nil
            }

            return Set(arrayLiteral: sender)
        }

        func recipientForOtherUsers() -> Set<ZMUser>? {
            guard conversation.connectedUser != nil || (otherUsers.isEmpty == false) else { return nil }
            if let connectedUser = conversation.connectedUser { return Set(arrayLiteral: connectedUser) }
            return Set(otherUsers)
        }

        func recipientsForDeletedEphemeral() -> Set<ZMUser>? {
            guard
                case .deleted? = content,
                conversation.conversationType == .group
            else {
                return nil
            }

            let nonce = UUID(uuidString: self.deleted.messageID)

            guard
                let managedObjectContext = conversation.managedObjectContext,
                let message = ZMMessage.fetch(withNonce: nonce, for: conversation, in: managedObjectContext),
                message.destructionDate != nil
            else {
                return nil
            }

            guard let sender = message.sender else {
                zmLog.error("sender of deleted ephemeral message \(String(describing: self.deleted.messageID)) is already cleared \n ConvID: \(String(describing: conversation.remoteIdentifier)) ConvType: \(conversation.conversationType.rawValue)")
                WireLogger.proteus.error("sender of deleted ephemeral message \(String(describing: self.deleted.messageID)) is already cleared \n ConvID: \(String(describing: conversation.remoteIdentifier)) ConvType: \(conversation.conversationType.rawValue)", attributes: nil)
                return Set(arrayLiteral: selfUser)
            }

            // If self deletes their own message, we want to send a delete message for everyone, so return nil.
            guard !sender.isSelfUser else { return nil }

            // Otherwise we delete only for self and the sender, all other recipients are unaffected.
            return Set(arrayLiteral: sender, selfUser)
        }

        func allAuthorizedRecipients() -> Set<ZMUser> {
            if let connectedUser = conversation.connectedUser { return Set(arrayLiteral: connectedUser, selfUser) }

            func mentionedServices() -> Set<ZMUser> {
                return services.filter { service in
                    self.textData?.mentions.contains { $0.userID == service.remoteIdentifier?.transportString() } ?? false
                }
            }

            let authorizedServices = ZMUser.servicesMustBeMentioned ? mentionedServices() : services

            return otherUsers.union(authorizedServices).union([selfUser])
        }

        var recipientUsers = Set<ZMUser>()

        switch content {
        case .confirmation?:
            guard let recipients = recipientForConfirmationMessage() ?? recipientForOtherUsers() else {
                let confirmationInfo = ", original message: \(String(describing: self.confirmation.firstMessageID))"
                fatal("confirmation need a recipient\n ConvType: \(conversation.conversationType.rawValue) \(confirmationInfo)")
            }
            recipientUsers = recipients
        case .buttonAction?:
            recipientUsers = recipientForButtonActionMessage()
        default:
            if let deletedEphemeral = recipientsForDeletedEphemeral() {
                recipientUsers = deletedEphemeral
            } else {
                recipientUsers = allAuthorizedRecipients()
            }
        }

        let hasRestrictions: Bool = {
            if conversation.connectedUser != nil { return recipientUsers.count != 2 }
            return recipientUsers.count != conversation.localParticipants.count
        }()

        let strategy: MissingClientsStrategy = hasRestrictions
            ? .ignoreAllMissingClientsNotFromUsers(users: recipientUsers)
            : .doNotIgnoreAnyMissingClient

        return (recipientUsers, strategy)
    }
}

// MARK: - External

extension GenericMessage {

    /// Returns a message with recipients, with the content stored externally, and a strategy to handle missing clients.

    private func encryptForTransportWithExternalDataBlob(for conversation: ZMConversation) -> EncryptedPayloadGenerator.Payload? {
        guard let encryptedDataWithKeys = GenericMessage.encryptedDataWithKeys(from: self) else { return nil }
        let externalGenericMessage = GenericMessage(content: External(withKeyWithChecksum: encryptedDataWithKeys.keys))
        return externalGenericMessage.encryptForTransport(for: conversation, externalData: encryptedDataWithKeys.data)
    }

    private func encryptForTransportWithExternalDataBlob(
        for recipients: [ZMUser: Set<UserClient>],
        with missingClientsStrategy: MissingClientsStrategy,
        useQualifiedIdentifiers: Bool = false,
        in context: NSManagedObjectContext
    ) -> Data? {
        guard
            let encryptedDataWithKeys = GenericMessage.encryptedDataWithKeys(from: self),
            let data = encryptedDataWithKeys.data,
            let keys = encryptedDataWithKeys.keys
        else {
            return nil
        }

        let externalGenericMessage = GenericMessage(content: External(withKeyWithChecksum: keys))
        var encryptedData: Data?

        context.proteusProvider.perform(
            withProteusService: { proteusService in
                encryptedData = externalGenericMessage.encrypt(
                    using: proteusService,
                    for: recipients,
                    with: missingClientsStrategy,
                    externalData: data,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            },
            withKeyStore: { keyStore in
                encryptedData = externalGenericMessage.legacyEncrypt(
                    using: keyStore,
                    for: recipients,
                    with: missingClientsStrategy,
                    externalData: data,
                    useQualifiedIdentifiers: useQualifiedIdentifiers,
                    in: context
                )
            }
        )

        return encryptedData
    }
}

// MARK: - MLS

/// A type that can generate payloads encrypted via mls.

public protocol MLSEncryptedPayloadGenerator {

    typealias EncryptionFunction = (Data) throws -> Data

    /// Encrypts data via MLS for sending to the backend.
    ///
    /// - Parameters:
    ///   - encrypt a function that encrpyts data using mls.
    ///
    /// - Returns:
    ///   Data encrypted with mls.
    ///
    /// - Throws: An `MLSEncryptedPayloadGeneratorError` or any error thrown from
    ///   the `encrypt` function.

    func encryptForTransport(using encrypt: EncryptionFunction) throws -> Data

}

public enum MLSEncryptedPayloadGeneratorError: Error {

    case noContext
    case noUnencryptedData

}

extension ZMClientMessage: MLSEncryptedPayloadGenerator {

    public func encryptForTransport(using encrypt: EncryptionFunction) throws -> Data {
        guard let context = managedObjectContext else {
            throw MLSEncryptedPayloadGeneratorError.noContext
        }

        updateUnderlayingMessageBeforeSending(in: context)

        guard let genericMessage = underlyingMessage else {
            throw MLSEncryptedPayloadGeneratorError.noUnencryptedData
        }

        return try genericMessage.encryptForTransport(using: encrypt)
    }

}

extension ZMAssetClientMessage: MLSEncryptedPayloadGenerator {

    public func encryptForTransport(using encrypt: EncryptionFunction) throws -> Data {
        guard let context = managedObjectContext else {
            throw MLSEncryptedPayloadGeneratorError.noContext
        }

        updateUnderlayingMessageBeforeSending(in: context)

        guard let genericMessage = underlyingMessage else {
            throw MLSEncryptedPayloadGeneratorError.noUnencryptedData
        }

        return try genericMessage.encryptForTransport(using: encrypt)
    }

}

extension GenericMessage: MLSEncryptedPayloadGenerator {

    public func encryptForTransport(using encrypt: MLSEncryptedPayloadGenerator.EncryptionFunction) throws -> Data {
        let unencryptedData = try unencryptedData()
        return try encrypt(unencryptedData)
    }

    private func unencryptedData() throws -> Data {
        do {
            return try serializedData()
        } catch let error {
            zmLog.warn("failed to get unencrypted data from generic message: \(String(describing: error))")
            throw MLSEncryptedPayloadGeneratorError.noUnencryptedData
        }
    }

}
