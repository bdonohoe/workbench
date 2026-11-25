import Testing
@testable import BenchKit

private let project = "/Users/matt/Apps/Typefully iOS/Typefully iOS"

@Test func dropsLeadingCD() {
    #expect(ShellStep.withoutCD(#"cd "\#(project)" && sed -n 1,5p a.swift"#) == "sed -n 1,5p a.swift")
    #expect(ShellStep.withoutCD("cd /tmp; cd x && ls") == "ls")
    #expect(ShellStep.withoutCD("git status") == "git status")
}

@Test func readsWithLineRange() throws {
    let read = try #require(ShellStep.read(#"cd "\#(project)" && sed -n 195,205p Views/PostView.swift"#))
    #expect(read.verbThen == "Read")
    #expect(read.target == "PostView.swift")
    #expect(read.note == "lines 195–205")
    #expect(read.path == project + "/Views/PostView.swift")
}

@Test func searches() throws {
    let read = try #require(ShellStep.read(#"cd "\#(project)" && grep -rn "PublishSuccess" --include=*.swift . | head -20"#))
    #expect(read.verbThen == "Searched for")
    #expect(read.target == "“PublishSuccess”")
    let rg = try #require(ShellStep.read(#"rg -n -A 3 "func logPost" Sources"#))
    #expect(rg.target == "“func logPost”")
    #expect(rg.note == "in Sources")
}

@Test func awkScriptWithComparisonIsARead() throws {
    let read = try #require(ShellStep.read(#"cd "\#(project)" && awk 'NR>=1130 && /^func/' Views/Composer.swift"#))
    #expect(read.target == "Composer.swift")
}

@Test func quietRedirectsStillRead() {
    #expect(ShellStep.read("cat a.txt 2>/dev/null") != nil)
    #expect(ShellStep.read("grep -r foo . 2>&1 | head") != nil)
}

@Test func changesAreNotReads() {
    #expect(ShellStep.read("sed -i '' 's/a/b/' x.swift") == nil)
    #expect(ShellStep.read("cat a > b") == nil)
    #expect(ShellStep.read("echo hi >> log.txt") == nil)
    #expect(ShellStep.read("find . -name '*.tmp' -delete") == nil)
    #expect(ShellStep.read("git checkout main") == nil)
    #expect(ShellStep.read("git branch -D old") == nil)
    #expect(ShellStep.read("make build") == nil)
    #expect(ShellStep.read("ls && rm x") == nil)
    #expect(ShellStep.read("python3 - <<'EOF'\nprint(1)\nEOF") == nil)
    #expect(ShellStep.read("cat x | sh") == nil)
    #expect(ShellStep.read("sleep 5 &") == nil)
}

@Test func gitReads() throws {
    #expect(try #require(ShellStep.read("git log --oneline -5")).note == "git history")
    #expect(try #require(ShellStep.read("git status --short")).verbThen == "Checked")
    #expect(ShellStep.read("git branch") != nil)
}

@Test func otherReadOnlyCommandsAreGeneric() throws {
    let read = try #require(ShellStep.read(#"cd "\#(project)" && echo $HOME"#))
    #expect(read.verbThen == "Ran")
    #expect(read.target == "echo $HOME")
}

@Test func heredocWrite() throws {
    let command = """
    cd "\(project)" && cat > Views/PostedBanner.swift <<'EOF'
    import SwiftUI

    struct PostedBanner: View {}
    EOF
    """
    let write = try #require(ShellStep.write(command))
    #expect(write.path == project + "/Views/PostedBanner.swift")
    #expect(write.content == "import SwiftUI\n\nstruct PostedBanner: View {}\n")
    #expect(!write.appends)
}

@Test func heredocVariants() throws {
    let tee = try #require(ShellStep.write("tee -a /tmp/notes.md <<EOF\nmore\nEOF"))
    #expect(tee.appends)
    #expect(tee.path == "/tmp/notes.md")
    let before = try #require(ShellStep.write("cat <<\"END\" > /tmp/a.txt\nhi\nEND\n"))
    #expect(before.content == "hi\n")
    // Something runs after the file is written: show the command instead.
    #expect(ShellStep.write("cat > /tmp/a.sh <<'EOF'\necho\nEOF\nchmod +x /tmp/a.sh") == nil)
    #expect(ShellStep.write("cat > /tmp/a <<'EOF' && make\nx\nEOF") == nil)
    #expect(ShellStep.write("python3 - <<'EOF'\nprint(1)\nEOF") == nil)
}

@Test func heredocBecomesAnEdit() throws {
    let command = "cd /tmp/proj && cat > Banner.swift <<'EOF'\nimport SwiftUI\nstruct Banner {}\nEOF"
    let edit = try #require(ToolEdit.from(tool: "Bash", input: ["command": command]))
    #expect(edit.isNewFile)
    #expect(edit.addedCount == 2)
    #expect(edit.added == ["import SwiftUI", "struct Banner {}"])
    #expect(ToolEdit.from(tool: "Bash", input: ["command": "ls"]) == nil)
}

@Test func pastTenseCoversJoinedVerbs() {
    #expect(ToolWording.pastClauses("Running tests and commit banner change") == "Ran tests and committed banner change")
    #expect(ToolWording.pastClauses("Using solid card, rebuild, capture") == "Used solid card, rebuilt, captured")
    #expect(ToolWording.pastClauses("Map success-flow state") == "Map success-flow state")
}
