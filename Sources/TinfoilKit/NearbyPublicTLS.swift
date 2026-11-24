import Foundation
import Network
import Security

/// TLS for a protocol whose requests are public and whose payloads are pinned locally.
/// The session is encrypted but the peer's identity is not trusted. Keep private traffic off it.
enum NearbyPublicTLS {
    enum Version: String, Sendable {
        case original = "tfk-public/1"
        case resumable = "tfk-public/2"
    }
    private static let trustQueue = DispatchQueue(label: "org.tinfoilkit.nearby-public-tls")

    static func listenerParameters() throws -> NWParameters {
        let options = makeTLSOptions()
        let identity = try PublicCertificate.makeIdentity()
        guard let protocolIdentity = sec_identity_create(identity) else { throw IdentityError.cannotCreateIdentity }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, protocolIdentity)
        let parameters = makeParameters(tls: options)
        parameters.acceptLocalOnly = true
        return parameters
    }

    static func clientParameters() -> NWParameters {
        let options = makeTLSOptions()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            // Trust comes from verifying the fetched public bytes against a local publisher pin.
            // TLS still requires the server to prove possession of its ephemeral certificate key.
            complete(true)
        }, trustQueue)
        return makeParameters(tls: options)
    }

    static func version(_ connection: NWConnection) -> Version? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13 else {
            return nil
        }
        if #available(iOS 18.5, macOS 15.5, *) {
            guard let negotiated = sec_protocol_metadata_copy_negotiated_protocol(metadata.securityProtocolMetadata) else {
                return nil
            }
            defer { free(UnsafeMutableRawPointer(mutating: negotiated)) }
            return Version(rawValue: String(cString: negotiated))
        }
        guard let negotiated = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) else {
            return nil
        }
        return Version(rawValue: String(cString: negotiated))
    }

    private static func makeTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(security, Version.resumable.rawValue)
        sec_protocol_options_add_tls_application_protocol(security, Version.original.rawValue)
        return options
    }

    private static func makeParameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private enum IdentityError: Error { case cannotCreateIdentity }

    private enum PublicCertificate {
        // ecdsa-with-SHA256, id-ecPublicKey, and prime256v1.
        private static let signatureAlgorithm = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2]))
        private static let keyAlgorithm = DER.sequence(
            DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]),
            DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7])
        )

        static func makeIdentity() throws -> SecIdentity {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]
            ]
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
                  let publicKey = SecKeyCopyPublicKey(privateKey),
                  let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  point.count == 65, point.first == 4 else {
                throw IdentityError.cannotCreateIdentity
            }

            let subject = DER.sequence(DER.field(0x31, DER.sequence(
                DER.oid([0x55, 4, 3]), DER.field(0x0c, Data("Tinfoil Kit Nearby Public".utf8))
            )))
            var serial = UUID().uuid
            let serialBytes = withUnsafeBytes(of: &serial) { Data($0) }
            let now = Date()
            let validity = DER.sequence(DER.time(now.addingTimeInterval(-300)), DER.time(now.addingTimeInterval(86_400)))
            let publicKeyInfo = DER.sequence(keyAlgorithm, DER.bitString(point))

            // A non-CA server certificate with digitalSignature and serverAuth usage.
            let extensions = DER.field(0xa3, DER.sequence(
                DER.sequence(DER.oid([0x55, 0x1d, 0x13]), DER.critical, DER.field(0x04, DER.sequence())),
                DER.sequence(DER.oid([0x55, 0x1d, 0x0f]), DER.critical, DER.field(0x04, DER.field(0x03, Data([7, 0x80])))),
                DER.sequence(DER.oid([0x55, 0x1d, 0x25]), DER.field(0x04, DER.sequence(
                    DER.oid([0x2b, 6, 1, 5, 5, 7, 3, 1])
                )))
            ))
            let tbs = DER.sequence(
                DER.field(0xa0, DER.integer(Data([2]))), DER.integer(serialBytes), signatureAlgorithm,
                subject, validity, subject, publicKeyInfo, extensions
            )
            guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) as Data?,
                  let certificate = SecCertificateCreateWithData(nil, DER.sequence(tbs, signatureAlgorithm, DER.bitString(signature)) as CFData),
                  let identity = SecIdentityCreate(nil, certificate, privateKey) else {
                throw IdentityError.cannotCreateIdentity
            }
            return identity
        }
    }

    /// The certificate is built entirely from local variables. Incoming certificates are parsed by Security.
    private enum DER {
        static let critical = Data([0x01, 1, 0xff])

        static func sequence(_ values: Data...) -> Data {
            field(0x30, values.reduce(into: Data()) { $0.append($1) })
        }

        static func oid(_ bytes: [UInt8]) -> Data { field(0x06, Data(bytes)) }
        static func bitString(_ bytes: Data) -> Data { field(0x03, Data([0]) + bytes) }

        static func integer(_ bytes: Data) -> Data {
            var magnitude = Data(bytes.drop(while: { $0 == 0 }))
            if magnitude.isEmpty || (magnitude.first ?? 0) >= 0x80 { magnitude.insert(0, at: 0) }
            return field(0x02, magnitude)
        }

        static func time(_ value: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let year = formatter.calendar.component(.year, from: value)
            let utc = (1950...2049).contains(year)
            formatter.dateFormat = utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
            return field(utc ? 0x17 : 0x18, Data(formatter.string(from: value).utf8))
        }

        static func field(_ tag: UInt8, _ bytes: Data) -> Data {
            if bytes.count < 128 { return Data([tag, UInt8(bytes.count)]) + bytes }
            var remaining = bytes.count
            var length: [UInt8] = []
            while remaining > 0 {
                length.append(UInt8(truncatingIfNeeded: remaining))
                remaining >>= 8
            }
            return Data([tag, 0x80 | UInt8(length.count)]) + Data(length.reversed()) + bytes
        }
    }
}
