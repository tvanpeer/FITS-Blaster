//
//  main.swift
//  FITS Blaster
//
//  Program entry point. Dispatches to CLI (headless) mode or the normal SwiftUI
//  app depending on how the binary was invoked.
//
//  CLI mode is triggered when any argument starts with /, ~ or -- (a folder path
//  or an explicit flag). Single-dash macOS system arguments such as
//  -NSDocumentRevisionsDebugMode or -ApplePersistenceIgnoreState are never matched.
//

import Foundation
import AppKit
import SwiftUI

private func isCLIArg(_ s: String) -> Bool {
    s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("--")
}

#if !APPSTORE
let headless = CommandLine.arguments.dropFirst().contains(where: isCLIArg)
#else
let headless = false
#endif

#if !APPSTORE
if headless {
    Task { @MainActor in
        await CLIRunner.run()
        exit(0)
    }
    RunLoop.main.run()
} else {
    FitsBlasterApp.main()
}
#else
FitsBlasterApp.main()
#endif
