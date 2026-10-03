import CoreText
import SwiftUI
import UIKit

enum ReadingTypography {
    static let fontName = "WoYuJianNiHeJuChunQiu"
    static var fontURL: URL? {
        Bundle.main.url(forResource: "WoYuJianNiHeJuChunQiu-2", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "WoYuJianNiHeJuChunQiu-2", withExtension: "ttf", subdirectory: "Fonts")
    }
    private static let registered: Void = {
        if let url = fontURL { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }()
    static func font(size: CGFloat, bold: Bool = false) -> UIFont {
        _ = registered
        if bold { return .boldSystemFont(ofSize: size) }
        return UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
    }
    static func swiftUIFont(size: CGFloat) -> Font { Font(font(size: size)) }
    static func appleFont(size: CGFloat, bold: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size)
    }
    static func isChinese(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F, 0x30000...0x323AF: return true
            default: return false
            }
        }
    }
}
