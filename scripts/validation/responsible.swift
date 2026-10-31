// Quem o TCC considera responsável por um PID. Só leitura.
import Foundation
typealias F = @convention(c) (pid_t) -> pid_t
let f = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid"), to: F.self)
func name(_ p: pid_t) -> String {
    var b = [UInt8](repeating: 0, count: 256)
    let n = proc_name(p, &b, 256)
    return String(decoding: b.prefix(Int(n)), as: UTF8.self)
}
for a in CommandLine.arguments.dropFirst() { let p = pid_t(a)!; let r = f(p); print(p, name(p), "responsavel:", r, name(r)) }
print("eu", getpid(), "responsavel:", f(getpid()), name(f(getpid())))
