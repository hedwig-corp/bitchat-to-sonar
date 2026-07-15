//
// MarmotServiceErrorTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct MarmotServiceErrorTests {
    @Test
    func serviceErrorsHaveActionableDescriptions() {
        #expect(
            MarmotService.ServiceError.notConnected.localizedDescription
                == "Not connected yet — try again in a moment."
        )
        #expect(
            MarmotService.ServiceError.cancelled.localizedDescription
                == "Operation cancelled."
        )
        #expect(
            MarmotService.ServiceError.invalidInput("bad group").localizedDescription
                == "Invalid input: bad group"
        )
        #expect(
            MarmotService.ServiceError.core("storage unavailable").localizedDescription
                == "storage unavailable"
        )
    }
}
