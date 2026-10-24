import Foundation
import Security

enum CodeSignature {
    // Ad hoc builds have a requirement tied to their own hash, which no update could match.
    static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code as! SecStaticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        return (text as String?)?.contains("cdhash") == true ? nil : requirement
    }

    static func satisfies(_ app: URL, _ requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
