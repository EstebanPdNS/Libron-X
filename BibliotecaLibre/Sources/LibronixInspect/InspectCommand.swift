import Foundation
import LibronixCore

/// JSON-only stdout makes private corpus checks composable without a GUI.
/// Named separately from main.swift so SwiftPM parses this @main entry as a library.
@main struct InspectCommand {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.first == "libron" {
                FileHandle.standardOutput.write(try await LibronInspection.run(Array(args.dropFirst()))); return
            }
            if args.first == "topic-audit", args.count >= 2 {
                var files = Set<String>(), at = 2, decodeTrees = false, verifyDestinations = false
                while at < args.count {
                    if args[at] == "--decode-trees" { decodeTrees = true; at += 1; continue }
                    if args[at] == "--verify-topic-destinations" { decodeTrees = true; verifyDestinations = true; at += 1; continue }
                    guard args[at] == "--file", at + 1 < args.count else { throw LibronixBookError.unsupportedProfile }
                    files.insert(args[at + 1]); at += 2
                }
                FileHandle.standardOutput.write(try await TopicInspection.run(args[1], files: files, decodeTrees: decodeTrees, verifyDestinations:verifyDestinations))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "format-audit", args.count >= 2 {
                var files = Set<String>(), all = false, at = 2
                while at < args.count {
                    if args[at] == "--all-articles" { all = true; at += 1 }
                    else if args[at] == "--file", at + 1 < args.count { files.insert(args[at + 1]); at += 2 }
                    else { throw LibronixBookError.unsupportedProfile }
                }
                FileHandle.standardOutput.write(try await ResourceFormatInspection.run(args[1], files: files, allArticles: all))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "language" {
                FileHandle.standardOutput.write(try LanguageInspection.run(Array(args.dropFirst())))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "postings" {
                FileHandle.standardOutput.write(try PostingsInspection.run(Array(args.dropFirst())))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "typography", args.count == 2 {
                FileHandle.standardOutput.write(try OutputInspection.typography(args[1])); FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "output" {
                FileHandle.standardOutput.write(try await OutputInspection.run(Array(args.dropFirst()))); FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "locator" {
                FileHandle.standardOutput.write(try await LocatorInspection.run(Array(args.dropFirst())))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "document", args.count == 2 {
                FileHandle.standardOutput.write(try DocumentInspection.run(args[1]))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if args.first == "search" {
                let options = try SearchInspection.Options(arguments: Array(args.dropFirst()))
                FileHandle.standardOutput.write(try await SearchInspection.run(options))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }
            guard args.count == 1 else {
                FileHandle.standardError.write(Data("Uso: libronix-inspect /ruta/a/biblioteca; para búsquedas: libronix-inspect search /ruta/a/biblioteca --file ARCHIVO --query CONSULTA\n".utf8))
                exit(64)
            }
            let result = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: args[0]))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as LanguageInspection.UsageError {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(64)
        } catch let error as PostingsInspection.UsageError {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(64)
        } catch let error as SearchInspection.UsageError {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(64)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
