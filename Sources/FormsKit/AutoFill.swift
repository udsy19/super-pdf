import Contacts
import Foundation
import SuperPDFCore

/// Where "AutoFill from my card" reads the person's details. The real one asks macOS for Contacts access the first
/// time the button is pressed (that press is the request; nothing reads Contacts before it) and reads only the "Me"
/// card. Self-tests inject their own and never touch Contacts.
protocol ContactCardReading: Sendable {
    /// The "Me" card as AutoFill values; nil when there is no Me card. Throws `ContactCardError.denied` when access is
    /// refused.
    func meCard() async throws -> AutoFillProfile?
}

enum ContactCardError: Error, Equatable { case denied }

/// The "Me" card from Contacts.
struct ContactsCard: ContactCardReading {
    func meCard() async throws -> AutoFillProfile? {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { throw ContactCardError.denied }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactPostalAddressesKey as CNKeyDescriptor, CNContactBirthdayKey as CNKeyDescriptor,
                                       CNContactOrganizationNameKey as CNKeyDescriptor]
        let me: CNContact
        do { me = try store.unifiedMeContactWithKeys(toFetch: keys) } catch { return nil }
        return Self.profile(of: me)
    }

    static func profile(of contact: CNContact) -> AutoFillProfile {
        var values: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { values[key] = value }
        }
        put(AutoFillKey.name, CNContactFormatter.string(from: contact, style: .fullName))
        put(AutoFillKey.firstName, contact.givenName)
        put(AutoFillKey.lastName, contact.familyName)
        put(AutoFillKey.email, contact.emailAddresses.first.map { $0.value as String })
        put(AutoFillKey.phone, contact.phoneNumbers.first?.value.stringValue)
        put(AutoFillKey.company, contact.organizationName)
        if let address = contact.postalAddresses.first?.value {
            put(AutoFillKey.street, address.street)
            put(AutoFillKey.city, address.city)
            put(AutoFillKey.state, address.state)
            put(AutoFillKey.postcode, address.postalCode)
            put(AutoFillKey.country, address.country)
        }
        if let birthday = contact.birthday, let year = birthday.year, let month = birthday.month, let day = birthday.day {
            put(AutoFillKey.birthday, String(format: "%04d-%02d-%02d", year, month, day))
        }
        return AutoFillProfile(values: values)
    }
}

/// The keys of `AutoFillProfile.values`: the Core list ("name", "email", "phone", "street", "city", "postcode",
/// "country", "birthday") plus the parts a form may ask for separately.
enum AutoFillKey {
    static let name = "name", email = "email", phone = "phone", street = "street", city = "city", postcode = "postcode"
    static let country = "country", birthday = "birthday"
    static let firstName = "firstName", lastName = "lastName", state = "state", company = "company"

    /// The profile key a field asks for, read from its name and tooltip ("txtFirstName", "E-mail address", "ZIP");
    /// nil when it asks for something else.
    static func key(for field: FormField) -> String? {
        let words = Self.words(field.tooltip + " " + field.id)
        let text = " " + words.joined(separator: " ") + " "
        func has(_ phrases: String...) -> Bool { phrases.contains { text.contains(" " + $0 + " ") } }
        if has("email", "e mail", "mail address") { return email }
        if has("phone", "telephone", "tel", "mobile", "cell", "phone number") { return phone }
        if has("first name", "given name", "firstname", "forename", "first") { return firstName }
        if has("last name", "surname", "family name", "lastname", "last") { return lastName }
        if has("zip", "zip code", "zipcode", "postcode", "postal code", "post code", "postal") { return postcode }
        if has("city", "town") { return city }
        if has("state", "province", "county", "region") { return state }
        if has("country") { return country }
        if has("birth", "birthday", "dob", "date of birth", "born") { return birthday }
        if has("company", "organization", "organisation", "employer", "business") { return company }
        if has("street", "address", "address line 1", "addr") { return street }
        if has("name", "full name", "your name", "applicant", "applicant name") { return name }
        return nil
    }

    /// Lower-case words, camel case split: "txtFirstName" → ["txt", "first", "name"].
    static func words(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if let previous, ch.isUppercase, previous.isLowercase, !current.isEmpty { words.append(current); current = "" }
                current.append(ch)
            } else if !current.isEmpty { words.append(current); current = "" }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}
