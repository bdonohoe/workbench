import Foundation

// bench-session: keeps Workbench's terminal sessions running while the
// app quits and relaunches, as for an update.
//
//   bench-session serve --socket <path>
//       The keeper. Workbench starts it; it ends once no sessions are left.
//   bench-session attach --socket <path> --tab <id> -- <shell command>
//       A tab's relay. Ghostty runs this in place of the shell.

var arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.isEmpty ? "" : arguments.removeFirst()
var options: [String: String] = [:]
var rest: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--" {
        rest = arguments
        break
    } else if argument.hasPrefix("--"), !arguments.isEmpty {
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    }
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: bench-session serve --socket <path>
           bench-session attach --socket <path> --tab <id> -- <shell command>

    """.utf8))
    exit(64)
}

guard let socket = options["socket"] else { usage() }
switch mode {
case "serve":
    Keeper(socketPath: socket).run()
case "attach":
    guard let tab = options["tab"] else { usage() }
    Relay.run(socket: socket, tab: tab, command: rest.isEmpty ? Shell.userShell : rest.joined(separator: " "))
default:
    usage()
}
