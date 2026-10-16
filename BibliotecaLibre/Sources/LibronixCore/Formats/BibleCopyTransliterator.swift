import Foundation

/// Procedural reimplementation of the two named copy-tool policies. The
/// original ICU data and rule source are research fixtures, never app assets.
public enum BibleCopyTransliterator {
    public static func hebrewLogos(_ text:String) -> String {
        let ignored:Set<UInt32> = Set((0x591...0x5af).filter{$0 != 0x5a2})
            .union([0x5bd,0x5bf,0x5c4,0x5f0,0x5f1,0x5f2,0x200a,0x200b])
        let source=Array(text.decomposedStringWithCanonicalMapping.unicodeScalars).filter{!ignored.contains($0.value)}
        let point:Set<UInt32> = Set(0x5b0...0x5b9).union([0x5bb,0x5bc,0x5c1,0x5c2])
        let vowel:Set<UInt32> = Set(0x5b0...0x5b9).union([0x5bb])
        let alphabet:Set<UInt32> = Set(0x5d0...0x5ea).union([0x5c1,0x5c2])
        let consonants:[UInt32:String] = [0x5d0:"ʾ",0x5d1:"b",0x5d2:"g",0x5d3:"d",0x5d4:"h",0x5d5:"w",0x5d6:"z",
            0x5d7:"h\u{323}",0x5d8:"t\u{323}",0x5d9:"y",0x5da:"k",0x5db:"k",0x5dc:"l",0x5dd:"m",0x5de:"m",
            0x5df:"n",0x5e0:"n",0x5e1:"s",0x5e2:"ʿ",0x5e3:"p",0x5e4:"p",0x5e5:"s\u{323}",0x5e6:"s\u{323}",
            0x5e7:"q",0x5e8:"r",0x5e9:"s\u{30c}",0x5ea:"t"]
        let marks:[UInt32:String] = [0x5b0:"ə",0x5b1:"e\u{30c}",0x5b2:"a\u{30c}",0x5b3:"a\u{30c}",0x5b4:"i",
            0x5b5:"e\u{304}",0x5b6:"e",0x5b7:"a",0x5b8:"a",0x5b9:"o",0x5bb:"u",0x5bc:"",0x5c1:"",0x5c2:""]
        let punctuation:[UInt32:String] = [0x5be:"-",0x5c0:"|",0x5c3:".",0x5f3:"'",0x5f4:"''"]
        let latinConsonants=Set("bcdfghjklmnpqrstvwxyz".unicodeScalars.map(\.value)),latinVowels=Set("aeiou".unicodeScalars.map(\.value))
        var output:[Unicode.Scalar]=[],cursor=0
        func append(_ string:String) { output.append(contentsOf:string.unicodeScalars) }
        func closedPrefix() -> Bool {
            let end=output.last?.value==0x323 ? output.count-1 : output.count
            guard end>=3 else { return false }
            return latinConsonants.contains(output[end-3].value) && latinVowels.contains(output[end-2].value) && latinConsonants.contains(output[end-1].value)
        }
        while cursor < source.count {
            let value=source[cursor].value
            if source[cursor].properties.generalCategory == .spaceSeparator {
                var end=cursor+1
                while end < source.count && source[end].properties.generalCategory == .spaceSeparator { end+=1 }
                if end-cursor>=2 && end < source.count && source[end].value==0x5e4 { append(" ¶");cursor=end+1;continue }
            }
            if value==0x5b4 || value==0x5b5 {
                var end=cursor+1
                while end < source.count && point.contains(source[end].value) { end+=1 }
                if end < source.count && source[end].value==0x5d9 && (end+1==source.count || !point.contains(source[end+1].value)) {
                    for mark in source[(cursor+1)..<end] { append(marks[mark.value] ?? String(mark)) }
                    append(value==0x5b4 ? "î" : "ê");cursor=end+1;continue
                }
            }
            if value==0x5d5 && cursor+1 < source.count {
                if source[cursor+1].value==0x5bc { append("û");cursor+=2;continue }
                if source[cursor+1].value==0x5b9 && (cursor+2==source.count || !point.contains(source[cursor+2].value)) {
                    append("ô");cursor+=2;continue
                }
            }
            if [0x5d4,0x5d7,0x5e2].contains(value), cursor+1 < source.count,source[cursor+1].value==0x5b7,
               output.last=="o" || output.last=="û" {
                append(value==0x5d4 ? "ah" : value==0x5d7 ? "ah\u{323}" : "aʿ");cursor+=2;continue
            }
            if value==0x5da && cursor+1 < source.count && source[cursor+1].value==0x5b0 { append("k");cursor+=2;continue }
            if value==0x5b0 && closedPrefix() {
                let next=cursor+1 < source.count ? source[cursor+1].value : nil
                let after=cursor+2 < source.count ? source[cursor+2].value : nil
                if let next,let after,alphabet.contains(next),vowel.contains(after) { cursor+=1;continue }
                if let next,alphabet.contains(next) || vowel.contains(next) { append("ə") }
                cursor+=1;continue
            }
            append(consonants[value] ?? marks[value] ?? punctuation[value] ?? String(source[cursor]));cursor+=1
        }
        return String(String.UnicodeScalarView(output)).precomposedStringWithCanonicalMapping
    }

    public static func greekSBL(_ text:String) -> String {
        let removed:Set<UInt32> = [0x300,0x301,0x302,0x342,0x384,0x308,0x345]
        var source=Array(text.decomposedStringWithCanonicalMapping.unicodeScalars).filter{!removed.contains($0.value)}
        let lowerVowels:Set<UInt32>=[0x3b1,0x3b5,0x3b7,0x3b9,0x3bf,0x3c5,0x3c9]
        let upperVowels:Set<UInt32>=[0x391,0x395,0x397,0x399,0x39f,0x3a5,0x3a9]
        let vowels=lowerVowels.union(upperVowels).union(Set("aeiouAEIOU".unicodeScalars.map(\.value)))
        var index=0
        // Attach breathing to the vowel group before letter substitution.
        while index < source.count {
            if source[index].value==0x314 && index>0 && vowels.contains(source[index-1].value) {
                var next=index+1
                while next<source.count && source[next].properties.generalCategory == .nonspacingMark { next+=1 }
                var start=index-1,prefix="H",lowercaseFirst=false
                if upperVowels.contains(source[index-1].value) && next<source.count && source[next].properties.generalCategory == .lowercaseLetter {
                    lowercaseFirst=true
                } else if lowerVowels.contains(source[index-1].value) {
                    while start>0 && lowerVowels.contains(source[start-1].value) { start-=1 }
                    if start>0 && upperVowels.contains(source[start-1].value) { start-=1;lowercaseFirst=true }
                    else { prefix="h" }
                } else { while start>0 && vowels.contains(source[start-1].value) { start-=1 } }
                source.remove(at:index)
                if lowercaseFirst { source[start]=String(source[start]).lowercased().unicodeScalars.first! }
                source.insert(contentsOf:prefix.unicodeScalars,at:start);index+=1
            }
            index+=1
        }
        let letters:[UInt32:String] = [0x391:"A",0x392:"B",0x393:"G",0x394:"D",0x395:"E",0x396:"Z",0x397:"E\u{304}",
            0x398:"TH",0x399:"I",0x39a:"K",0x39b:"L",0x39c:"M",0x39d:"N",0x39e:"X",0x39f:"O",0x3a0:"P",0x3a1:"R",
            0x3a3:"S",0x3a4:"T",0x3a5:"Y",0x3a6:"PH",0x3a7:"CH",0x3a8:"PS",0x3a9:"O\u{304}",
            0x3b1:"a",0x3b2:"b",0x3b3:"g",0x3b4:"d",0x3b5:"e",0x3b6:"z",0x3b7:"e\u{304}",0x3b8:"th",0x3b9:"i",
            0x3ba:"k",0x3bb:"l",0x3bc:"m",0x3bd:"n",0x3be:"x",0x3bf:"o",0x3c0:"p",0x3c1:"r",0x3c2:"s",0x3c3:"s",
            0x3c4:"t",0x3c5:"y",0x3c6:"ph",0x3c7:"ch",0x3c8:"ps",0x3c9:"o\u{304}"]
        let gammaNext:Set<UInt32>=[0x393,0x39a,0x39e,0x3a7,0x3b3,0x3ba,0x3be,0x3c7]
        var result="",cursor=0
        while cursor < source.count {
            let value=source[cursor].value
            if [0x313,0x314,0x1fbf,0x1ffe].contains(value) { cursor+=1;continue }
            var mapped=letters[value] ?? String(source[cursor])
            if [0x393,0x3b3].contains(value),cursor+1 < source.count,gammaNext.contains(source[cursor+1].value) {
                mapped=value==0x393 ? "N" : "n"
            }
            if [0x398,0x3a6,0x3a7,0x3a8].contains(value),cursor+1 < source.count,source[cursor+1].properties.generalCategory == .lowercaseLetter {
                mapped=String(mapped.prefix(1))+mapped.dropFirst().lowercased()
            }
            if [0x3a1,0x3c1].contains(value),cursor+1 < source.count,source[cursor+1].value==0x314 {
                var next=cursor+2
                while next<source.count && source[next].properties.generalCategory == .nonspacingMark { next+=1 }
                mapped=value==0x3c1 ? "rh" : next<source.count && source[next].properties.generalCategory == .lowercaseLetter ? "Rh" : "RH"
            }
            if [0x3a5,0x3c5].contains(value) {
                var prior=cursor-1
                while prior>=0 && source[prior].properties.generalCategory == .nonspacingMark { prior-=1 }
                var next=cursor+1
                while next<source.count && source[next].properties.generalCategory == .nonspacingMark { next+=1 }
                if prior>=0 && vowels.contains(source[prior].value) || next<source.count && [0x399,0x3b9].contains(source[next].value) {
                    mapped=value==0x3a5 ? "U" : "u"
                }
            }
            if [0x3b,0x37e].contains(value) { mapped="?" }
            if [0xb7,0x387].contains(value) { mapped=";" }
            result+=mapped;cursor+=1
        }
        return result.precomposedStringWithCanonicalMapping
    }
}
