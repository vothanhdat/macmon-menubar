import Foundation
import Testing
@testable import MacMonIndicator

@Suite struct NetTopTests {
    private typealias Bytes = NetTopParser.Bytes
    private let header = ",bytes_in,bytes_out,\r\n"

    /// A parser that names programs "/bin/<name>", and what it was asked to name.
    private func parser(_ asked: Box<[pid_t]> = Box([])) -> NetTopParser {
        NetTopParser { pid, name in asked.value.append(pid); return "/bin/" + name }
    }

    private final class Box<T> {
        var value: T
        init(_ v: T) { value = v }
    }

    @Test func firstSampleOnlySetsTheStartingPoint() {
        var p = parser()
        // Connections already open have carried this before nettop started.
        #expect(p.consume(Data((header + "ssh.10,5000,300,\r\ncurl.11,10,20,\r\n").utf8)).isEmpty)
        let moved = p.consume(Data((header + "ssh.10,5600,300,\r\ncurl.11,10,20,\r\n").utf8))
        #expect(moved == ["/bin/ssh": Bytes(received: 600, sent: 0)])
    }

    @Test func laterProcessesCountInFull() {
        var p = parser()
        _ = p.consume(Data((header + "ssh.10,5000,300,\r\n").utf8))
        let moved = p.consume(Data((header + "ssh.10,5000,300,\r\ncurl.11,1500,90,\r\n").utf8))
        #expect(moved == ["/bin/curl": Bytes(received: 1500, sent: 90)])
    }

    @Test func copiesOfOneProgramAddUp() {
        let asked = Box<[pid_t]>([])
        var p = parser(asked)
        _ = p.consume(Data(header.utf8))
        let moved = p.consume(Data((header + "node.20,100,10,\r\nnode.21,50,5,\r\n").utf8))
        #expect(moved == ["/bin/node": Bytes(received: 150, sent: 15)])
        // The program is looked up once per process, not once per sample.
        _ = p.consume(Data((header + "node.20,300,10,\r\nnode.21,50,5,\r\n").utf8))
        #expect(asked.value.sorted() == [20, 21])
    }

    @Test func aReusedPidStartsAgain() {
        var p = parser()
        _ = p.consume(Data(header.utf8))
        _ = p.consume(Data((header + "node.20,9000,900,\r\n").utf8))
        // Lower than before: not the same process.
        #expect(p.consume(Data((header + "node.20,40,4,\r\n").utf8)) == ["/bin/node": Bytes(received: 40, sent: 4)])
        // Gone for a sample, then back: also a new process.
        _ = p.consume(Data(header.utf8))
        _ = p.consume(Data(header.utf8))
        #expect(p.consume(Data("node.20,70,7,\r\n".utf8)) == ["/bin/node": Bytes(received: 70, sent: 7)])
    }

    @Test func linesCanArriveInPieces() {
        var p = parser()
        _ = p.consume(Data((header + "Google Chrome H.105").utf8))
        _ = p.consume(Data(("34,100,10,\r\n" + header + "Google Chrome H.10534,").utf8))
        #expect(p.consume(Data("350,10,\r\n".utf8)) == ["/bin/Google Chrome H": Bytes(received: 250, sent: 0)])
    }

    @Test func namesCanHoldDotsAndCommas() {
        var p = parser()
        _ = p.consume(Data(header.utf8))
        let moved = p.consume(Data((header + "io.tailscale.ip.1180,10,20,\r\na,b.7,1,2,\r\nnot a row\r\nx.y,1,2,\r\n").utf8))
        #expect(moved == ["/bin/io.tailscale.ip": Bytes(received: 10, sent: 20), "/bin/a,b": Bytes(received: 1, sent: 2)])
    }

    @Test func thisProcessHasAPath() {
        // The real lookup: a path for a running process, nettop's name for one that is gone.
        #expect(NetTopParser.program(getpid(), "x").hasPrefix("/"))
        #expect(NetTopParser.program(0, "kernel_task") == "kernel_task")
    }
}
