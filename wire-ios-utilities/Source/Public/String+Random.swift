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

public extension String {

    static func randomDomain(hostLength: UInt = 5) -> String {
        return "\(String.random(length: hostLength)).com"
    }

    static func random(length: UInt) -> String {
        let randomChars = (0..<length).compactMap { _ in
            "a...z".randomElement()
        }

        return String(randomChars)
    }

}
