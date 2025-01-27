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
import XCTest
import WireCoreCrypto
@testable import WireDataModel

class ProteusServiceTests: XCTestCase {

    struct MockError: Error {}

    var mockCoreCrypto: MockCoreCrypto!
    var mockSafeCoreCrypto: MockSafeCoreCrypto!
    var sut: ProteusService!

    // MARK: - Set up

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockCoreCrypto = MockCoreCrypto()
        mockCoreCrypto.mockProteusInit = {}
        mockSafeCoreCrypto = MockSafeCoreCrypto(coreCrypto: mockCoreCrypto)
        sut = try ProteusService(coreCrypto: mockSafeCoreCrypto)
    }

    override func tearDown() {
        mockCoreCrypto = nil
        mockSafeCoreCrypto = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - Decrypting messages

    func test_DecryptDataForSession_SessionExists() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let encryptedData = Data.secureRandomData(length: 8)

        // Mock
        mockCoreCrypto.mockProteusSessionExists = { id in
            XCTAssertEqual(id, sessionID.rawValue)
            return true
        }

        mockCoreCrypto.mockProteusDecrypt = { id, ciphertext in
            XCTAssertEqual(id, sessionID.rawValue)
            XCTAssertEqual(ciphertext, encryptedData.bytes)
            return [0, 1, 2, 3, 4, 5]
        }

        // When
        let (didCreateSession, decryptedData) = try sut.decrypt(
            data: encryptedData,
            forSession: sessionID
        )

        // Then
        XCTAssertFalse(didCreateSession)
        XCTAssertEqual(decryptedData, Data([0, 1, 2, 3, 4, 5]))
    }

    func test_DecryptDataForSession_SessionExists_Failure() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let encryptedData = Data.secureRandomData(length: 8)

        // Mock
        mockCoreCrypto.mockProteusSessionExists = { id in
            XCTAssertEqual(id, sessionID.rawValue)
            return true
        }

        mockCoreCrypto.mockProteusLastErrorCode = {
            return 209
        }

        mockCoreCrypto.mockProteusDecrypt = { _, _ in
            throw MockError()
        }

        // Then
        assertItThrows(error: ProteusService.DecryptionError.failedToDecryptData(.duplicateMessage)) {
            // When
            _ = try sut.decrypt(
                data: encryptedData,
                forSession: sessionID
            )
        }
    }

    func test_DecryptDataForSession_SessionDoesNotExist() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let encryptedData = Data.secureRandomData(length: 8)

        // Mock
        mockCoreCrypto.mockProteusSessionExists = { id in
            XCTAssertEqual(id, sessionID.rawValue)
            return false
        }

        mockCoreCrypto.mockProteusSessionFromMessage = { id, ciphertext in
            XCTAssertEqual(id, sessionID.rawValue)
            XCTAssertEqual(ciphertext, encryptedData.bytes)
            return [0, 1, 2, 3, 4, 5]
        }

        // When
        let (didCreateSession, decryptedData) = try sut.decrypt(
            data: encryptedData,
            forSession: sessionID
        )

        // Then
        XCTAssertTrue(didCreateSession)
        XCTAssertEqual(decryptedData, Data([0, 1, 2, 3, 4, 5]))
    }

    func test_DecryptDataForSession_SessionDoesNotExist_Failure() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let encryptedData = Data.secureRandomData(length: 8)

        // Mock
        mockCoreCrypto.mockProteusSessionExists = { id in
            XCTAssertEqual(id, sessionID.rawValue)
            return false
        }

        mockCoreCrypto.mockProteusLastErrorCode = {
            return 209
        }

        mockCoreCrypto.mockProteusSessionFromMessage = { _, _ in
            throw MockError()
        }

        // Then
        assertItThrows(error: ProteusService.DecryptionError.failedToEstablishSessionFromMessage(.duplicateMessage)) {
            // When
            _ = try sut.decrypt(
                data: encryptedData,
                forSession: sessionID
            )
        }
    }

    // MARK: - Encrypting messages

    func test_EncryptDataForSession_Success() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let plaintext = Data.secureRandomData(length: 8)

        // Mock
        var encryptCalls = 0
        mockCoreCrypto.mockProteusEncrypt = { sessionIDString, plaintextBytes in
            encryptCalls += 1
            XCTAssertEqual(sessionIDString, sessionID.rawValue)
            XCTAssertEqual(plaintextBytes, plaintext.bytes)
            return [1, 2, 3, 4, 5]
        }

        // When
        let encryptedData = try sut.encrypt(
            data: plaintext,
            forSession: sessionID
        )

        // Then
        XCTAssertEqual(encryptCalls, 1)
        XCTAssertEqual(encryptedData, Data([1, 2, 3, 4, 5]))
    }

    func test_EncryptDataForSession_Fail() throws {
        // Given
        let sessionID = ProteusSessionID.random()
        let plaintext = Data.secureRandomData(length: 8)

        // Mock
        var encryptCalls = 0
        mockCoreCrypto.mockProteusEncrypt = { sessionIDString, plaintextBytes in
            encryptCalls += 1
            XCTAssertEqual(sessionIDString, sessionID.rawValue)
            XCTAssertEqual(plaintextBytes, plaintext.bytes)
            throw MockError()
        }

        // Then
        assertItThrows(error: ProteusService.EncryptionError.failedToEncryptData) {
            // When
            _ = try sut.encrypt(
                data: plaintext,
                forSession: sessionID
            )
        }

        XCTAssertEqual(encryptCalls, 1)
    }

    // MARK: - Session deletion

    func test_DeleteSession_Success() throws {
        // Given
        let sessionID = ProteusSessionID.random()

        // Mock
        var sessionDeleteCalls = [String]()
        mockCoreCrypto.mockProteusSessionDelete = {
            sessionDeleteCalls.append($0)
        }

        // When
        try sut.deleteSession(id: sessionID)

        // Then
        XCTAssertEqual(sessionDeleteCalls, [sessionID.rawValue])
    }

    func test_DeleteSession_Failure() throws {
        // Given
        let sessionID = ProteusSessionID.random()

        // Mock
        mockCoreCrypto.mockProteusSessionDelete = { _ in
            throw MockError()
        }

        // Then
        assertItThrows(error: ProteusService.DeleteSessionError.failedToDeleteSession) {
            // When
            try sut.deleteSession(id: sessionID)
        }
    }

}

// MARK: - Helpers

private extension ProteusSessionID {

    static func random() -> Self {
        ProteusSessionID(
            domain: .randomDomain(),
            userID: UUID.create().uuidString,
            clientID: .random(length: 6)
        )
    }

}
