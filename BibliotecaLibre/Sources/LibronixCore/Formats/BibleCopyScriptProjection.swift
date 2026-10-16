import Foundation

/// Script transformations operate on a copy. Book text, fingerprints and
/// source UTF-16 coordinates retain the untransformed source representation.
public enum BibleCopyScriptProjection {
    public static func hebrew(_ text:String,letters:BibleCopyHebrewLetters = .full) -> String {
        let source=Array(text.unicodeScalars)
        var final:[Unicode.Scalar]=[]
        let forms:[UInt32:UInt32]=[0x5db:0x5da,0x5de:0x5dd,0x5e0:0x5df,0x5e4:0x5e3,0x5e6:0x5e5]
        for (index,scalar) in source.enumerated() {
            var value=scalar
            if let terminal=forms[scalar.value] {
                let next=source.dropFirst(index+1).first { !isHebrewPoint($0.value) }
                if next == nil || !(0x5d0...0x5ea).contains(next!.value) { value=Unicode.Scalar(terminal)! }
            }
            switch letters {
            case .full:break
            case .consonantsAndVowels:
                if (0x591...0x5af).contains(value.value) || [0x5bf,0x5c0,0x5c4].contains(value.value) { continue }
            case .consonantsOnly:
                if value.value==0x5be { final.append(" ");continue }
                if (0x591...0x5c4).contains(value.value) { continue }
            }
            final.append(value)
        }
        return String(String.UnicodeScalarView(final))
    }
    private static func isHebrewPoint(_ value:UInt32) -> Bool {
        (0x591...0x5bd).contains(value) || [0x5bf,0x5c1,0x5c2,0x5c4,0x5c5,0x5c7].contains(value)
    }
}
