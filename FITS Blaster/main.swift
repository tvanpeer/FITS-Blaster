//
//  main.swift
//  FITS Blaster
//
//  Program entry point. Dispatches to CLI (headless) mode or the normal SwiftUI
//  app depending on how the binary was invoked.
//
//  CLI mode: see `CLIArguments.isCLIInvocation` (one of the CLI's options, a path
//  starting with / or ~, or a relative path to a folder that exists). macOS's own
//  arguments such as -NSDocumentRevisionsDebugMode YES open the window.
//

import Foundation
import AppKit
import SwiftUI

#if !APPSTORE
let headless = CLIArguments.isCLIInvocation(Array(CommandLine.arguments.dropFirst()),
                                             currentDirectory: .currentDirectory())
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
