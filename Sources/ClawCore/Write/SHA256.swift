import Foundation

/// SHA-256 (FIPS 180-4), written out so the core needs no dependency: CryptoKit is macOS only and swift-crypto
/// would be a third-party package. Used to notice changed files, on config files of a few hundred kilobytes.
public enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    /// The digest as lowercase hexadecimal.
    public static func hex(_ data: Data) -> String {
        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        message += [UInt8](repeating: 0, count: (120 - message.count % 64) % 64)
        message += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> (UInt64($0) * 8)) }

        var schedule = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: message.count, by: 64) {
            for word in 0..<16 {
                let at = block + word * 4
                schedule[word] =
                    UInt32(message[at]) << 24 | UInt32(message[at + 1]) << 16 | UInt32(message[at + 2]) << 8
                    | UInt32(message[at + 3])
            }
            for word in 16..<64 {
                let low = schedule[word - 15]
                let high = schedule[word - 2]
                let sigma0 = rotate(low, 7) ^ rotate(low, 18) ^ (low >> 3)
                let sigma1 = rotate(high, 17) ^ rotate(high, 19) ^ (high >> 10)
                schedule[word] = schedule[word - 16] &+ sigma0 &+ schedule[word - 7] &+ sigma1
            }
            var work = state
            for round in 0..<64 {
                let sum1 = rotate(work[4], 6) ^ rotate(work[4], 11) ^ rotate(work[4], 25)
                let choice = (work[4] & work[5]) ^ (~work[4] & work[6])
                let first = work[7] &+ sum1 &+ choice &+ constants[round] &+ schedule[round]
                let sum0 = rotate(work[0], 2) ^ rotate(work[0], 13) ^ rotate(work[0], 22)
                let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
                work = [first &+ sum0 &+ majority, work[0], work[1], work[2], work[3] &+ first, work[4], work[5], work[6]]
            }
            for index in 0..<8 { state[index] &+= work[index] }
        }
        return state.map { word in
            let digits = String(word, radix: 16)
            return String(repeating: "0", count: 8 - digits.count) + digits
        }.joined()
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
