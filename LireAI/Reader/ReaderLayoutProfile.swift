import Foundation
import CoreFoundation
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Layout-affecting reader settings shared by the live reader and the import-time
/// pagination precomputer. Keeping them in one place makes a cached page-count
/// map valid for exactly the layout the user will later see.
enum ReaderLayoutProfile {
    static let fontSizes: [Double] = stride(from: 90, through: 150, by: 2).map { Double($0) / 100.0 }

    static func preferences(fontSize: Double, theme: ReaderThemeMode = .warm) -> EPUBPreferences {
        EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: theme.paperHex),
            fontFamily: .iowanOldStyle,
            fontSize: fontSize,
            hyphens: true,
            letterSpacing: 0,
            lineHeight: 1.35,
            pageMargins: 1.8,
            publisherStyles: false,
            scroll: false,
            textAlign: .start,
            textColor: ReadiumNavigator.Color(hex: theme.textHex),
            theme: theme.readiumTheme,
            wordSpacing: 0
        )
    }

    static func configuration(
        fontSize: Double,
        theme: ReaderThemeMode = .warm,
        editingActions: [EditingAction] = []
    ) -> EPUBNavigatorViewController.Configuration {
        var config = EPUBNavigatorViewController.Configuration(
            preferences: preferences(fontSize: fontSize, theme: theme),
            editingActions: editingActions,
            fontFamilyDeclarations: [
                CSSFontFamilyDeclaration(fontFamily: .iowanOldStyle, alternates: [.palatino, .georgia, .serif])
                    .eraseToAnyHTMLFontFamilyDeclaration()
            ]
        )
        config.contentInset = [
            .compact: (top: 106, bottom: 88),
            .regular: (top: 112, bottom: 92)
        ]
        return config
    }
}
