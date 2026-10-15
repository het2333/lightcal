import Foundation

while let line = readLine() {
    guard let data = Data(base64Encoded: line),
          let text = String(data: data, encoding: .utf8) else {
        print("")
        continue
    }
    let simplified = text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
    let output = Data(simplified.utf8).base64EncodedString()
    print(output)
}
