// Consulta a autorização do microfone para este processo. TCCAccessPreflight nunca abre diálogo.
import Foundation
let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
typealias F = @convention(c) (CFString, CFDictionary?) -> Int32
print(unsafeBitCast(dlsym(h, "TCCAccessPreflight"), to: F.self)("kTCCServiceMicrophone" as CFString, nil))
