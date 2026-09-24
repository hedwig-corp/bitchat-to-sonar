// qr-decode.swift — print the payload of every QR code in an image (macOS,
// CoreImage). Used by android-smoke.sh QA-041 to prove the profile's
// "scan this to add you" code is a real QR of the npub.
//
//   swift scripts/qa/qr-decode.swift screenshot.png
import CoreImage
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = CIImage(contentsOf: url) else { print("no image"); exit(1) }
let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let feats = det.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
print(feats.isEmpty ? "NO QR FOUND" : feats.joined(separator: "\n"))
