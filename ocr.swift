import Foundation
import Darwin

@main
struct OCRCommand {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let options: Options
        do { options = try parseOptions(Array(CommandLine.arguments.dropFirst())) }
        catch {
            stderrPrint(error.localizedDescription)
            exit(2)
        }
        if options.showHelp { printHelp(); return }
        if options.showVersion { print("ocr \(toolVersion) (schema \(schemaVersion))"); return }
        if options.listLanguages {
            do { print(try supportedLanguages(options: options).joined(separator: "\n")) }
            catch { stderrPrint(error.localizedDescription); exit(1) }
            return
        }
        var writer: OutputWriter?
        do {
            let output = try OutputWriter(options: options)
            writer = output
            let success = try await Pipeline(options: options, writer: output).run()
            exit(success ? 0 : 1)
        } catch {
            writer?.abort()
            stderrPrint(error.localizedDescription)
            exit(1)
        }
    }
}
