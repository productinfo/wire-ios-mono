//
// Wire
// Copyright (C) 2021 Wire Swiss GmbH
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
import WireSystem
import WireDataModel

private let zmLog = ZMSLog(tag: "ZMClientRegistrationStatus")

extension ZMClientRegistrationStatus {
    @objc(didFailToRegisterClient:)
    public func didFail(toRegisterClient error: NSError) {
        zmLog.debug(#function)

        var error: NSError = error

        // we should not reset login state for client registration errors
        if error.code != ZMUserSessionErrorCode.needsPasswordToRegisterClient.rawValue && error.code != ZMUserSessionErrorCode.needsToRegisterEmailToRegisterClient.rawValue && error.code != ZMUserSessionErrorCode.canNotRegisterMoreClients.rawValue {
            emailCredentials = nil
        }

        if error.code == ZMUserSessionErrorCode.needsPasswordToRegisterClient.rawValue {
            // help the user by providing the email associated with this account
            error = NSError(domain: error.domain, code: error.code, userInfo: ZMUser.selfUser(in: managedObjectContext).loginCredentials.dictionaryRepresentation)
        }

        if error.code == ZMUserSessionErrorCode.needsPasswordToRegisterClient.rawValue || error.code == ZMUserSessionErrorCode.invalidCredentials.rawValue {
            // set this label to block additional requests while we are waiting for the user to (re-)enter the password
            needsToCheckCredentials = true
        }

        if error.code == ZMUserSessionErrorCode.canNotRegisterMoreClients.rawValue {
            // Wait and fetch the clients before sending the error
            isWaitingForUserClients = true
            RequestAvailableNotification.notifyNewRequestsAvailable(self)
        } else {
            registrationStatusDelegate?.didFailToRegisterSelfUserClient(error: error)
        }
    }

    @objc
    public func invalidateCookieAndNotify() {
        emailCredentials = nil
        cookieStorage.deleteKeychainItems()

        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        let outError = NSError.userSessionErrorWith(ZMUserSessionErrorCode.clientDeletedRemotely, userInfo: selfUser.loginCredentials.dictionaryRepresentation)
        registrationStatusDelegate?.didDeleteSelfUserClient(error: outError)
    }

    @objc
    public func prepareForClientRegistration() {
        WireLogger.userClient.info("preparing for client registration")

        guard needsToRegisterClient() else {
            WireLogger.userClient.info("no need to register client. aborting client registration")
            return
        }

        let selfUser = ZMUser.selfUser(in: managedObjectContext)

        guard selfUser.remoteIdentifier != nil else {
            WireLogger.userClient.info("identifier for self user is nil. aborting client registration")
            return
        }

        if needsToCreateNewClientForSelfUser(selfUser) {
            WireLogger.userClient.info("client creation needed. will insert client in context")
            insertNewClient(for: selfUser)
        } else {
            // there is already an unregistered client in the store
            // since there is no change in the managedObject, it will not trigger [ZMRequestAvailableNotification notifyNewRequestsAvailable:] automatically
            // therefore we need to call it here
            WireLogger.userClient.info("unregistered client found. notifying available requests")
            RequestAvailableNotification.notifyNewRequestsAvailable(self)
        }
    }

    private func insertNewClient(for selfUser: ZMUser) {
        UserClient.insertNewSelfClient(
            in: managedObjectContext,
            selfUser: selfUser,
            model: UIDevice.current.zm_model(),
            label: UIDevice.current.name
        )

        managedObjectContext.saveOrRollback()
    }

    private func needsToCreateNewClientForSelfUser(_ selfUser: ZMUser) -> Bool {
        if let selfClient = selfUser.selfClient(), !selfClient.isZombieObject {
            WireLogger.userClient.info("self user has viable self client. no need to create new self client")
            return false
        }

        let hasNotYetRegisteredClient = selfUser.clients.contains(where: { $0.remoteIdentifier == nil })

        if !hasNotYetRegisteredClient {
            WireLogger.userClient.info("self user has no client that isn't yet registered. will need to create new self client")
        } else {
            WireLogger.userClient.info("self user has a client that isn't yet registered. no need to create new self client")
        }

        return !hasNotYetRegisteredClient
    }

    @objc
    public func didDeleteClient() {
        WireLogger.userClient.info("client was deleted. will prepare for registration")

        if isWaitingForClientsToBeDeleted {
            isWaitingForClientsToBeDeleted = false
            prepareForClientRegistration()
        }
    }

    @objc
    public func didFetchSelfUser() {
        WireLogger.userClient.info("did fetch self user")

        if needsToRegisterClient() {
            if isAddingEmailNecessary() {
                notifyEmailIsNecessary()
            }
            prepareForClientRegistration()
        } else if !needsToVerifySelfClient {
            emailCredentials = nil
        }
    }

    private func notifyEmailIsNecessary() {
        let error = NSError(
            domain: NSError.ZMUserSessionErrorDomain,
            code: Int(ZMUserSessionErrorCode.needsToRegisterEmailToRegisterClient.rawValue)
        )

        registrationStatusDelegate.didFailToRegisterSelfUserClient(error: error)
    }

}
