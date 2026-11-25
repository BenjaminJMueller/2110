// Liest einen privaten Sparkle-Schlüssel (Base64, 32 Byte) von der Standardeingabe
// und gibt den zugehörigen öffentlichen Schlüssel (Base64) aus.
import CryptoKit
import Foundation

let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write("Kein gültiger Schlüssel (erwartet: Base64, 32 Byte)\n".data(using: .utf8)!)
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
