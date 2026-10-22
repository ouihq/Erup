import XCTest
@testable import ScooterProtocol

final class ATTests: XCTestCase {
    private func text(_ command: ATCommand) throws -> String {
        String(decoding: try command.encoded(), as: UTF8.self)
    }

    func testEncoding() throws {
        XCTAssertEqual(try text(.rename(suffix: "Blitz")), "AT+NAME[ZYD_Blitz]")
        XCTAssertEqual(try text(.verifyPIN("123456")), "AT+PWD[123456]")
        XCTAssertEqual(try text(.changePIN("654321")), "AT+PWDM[654321]")
        XCTAssertEqual(try text(.queryPINEnabled), "AT+TYPE?")
        XCTAssertEqual(try text(.queryDevice), "AT+DEVICE?")
    }

    /// The original app sends the PIN switch with an unclosed bracket.
    func testPINEnabledUsesUnclosedBracket() throws {
        XCTAssertEqual(try text(.setPINEnabled(true)), "AT+TYPE[B")
        XCTAssertEqual(try text(.setPINEnabled(false)), "AT+TYPE[A")
    }

    func testExpectedKeys() throws {
        XCTAssertEqual(ATCommand.changePIN("123456").expectedReplyKey, "PWDM")
        XCTAssertEqual(ATCommand.rename(suffix: "x").expectedReplyKey, "NAME")
    }

    func testArgumentValidation() {
        XCTAssertThrowsError(try ATCommand.rename(suffix: "").encoded())
        XCTAssertThrowsError(try ATCommand.rename(suffix: "has space").encoded())
        XCTAssertThrowsError(try ATCommand.verifyPIN("12345").encoded())
        XCTAssertThrowsError(try ATCommand.changePIN("12a456").encoded())
    }

    func testRenameAlwaysKeepsPrefix() throws {
        XCTAssertTrue(try text(.rename(suffix: "x")).hasPrefix("AT+NAME[" + GATT.namePrefix))
    }

    func testReplyParsing() throws {
        let pwd = try ATReply.parse(Array("OK+PWD:Y".utf8))
        XCTAssertEqual(pwd, ATReply(status: .ok, key: "PWD", value: "Y"))

        let pwdm = try ATReply.parse(Array("OK+PWDM".utf8))
        XCTAssertEqual(pwdm.key, "PWDM")
        XCTAssertEqual(pwdm.value, "")

        let name = try ATReply.parse(Array("ERR+NAME:\r\n".utf8))
        XCTAssertFalse(name.isOK)
        XCTAssertEqual(name.key, "NAME")

        XCTAssertEqual(try ATReply.parse(Array("OK+TYPE:B".utf8)).value, "B")
        XCTAssertEqual(try ATReply.parse(Array("OK+DEVICE[012345 ]".utf8)).value, "012345")
    }

    func testUnrecognizedReplyIsAnError() {
        XCTAssertThrowsError(try ATReply.parse(Array("garbage".utf8))) {
            XCTAssertEqual($0 as? ProtocolError, .unrecognizedATReply("garbage"))
        }
        XCTAssertThrowsError(try ATReply.parse(Array("OK+WAT:1".utf8)))
    }
}
