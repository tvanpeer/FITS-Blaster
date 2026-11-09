//
//  SoftwareUpdatesSection.swift
//  FITS Blaster
//
//  The Software Updates section of Settings (direct builds only). A stable build has the
//  "Receive beta releases" switch; a beta build always checks the beta feed, so it says so
//  instead (UpdateChannel, issue #11).
//

#if !APPSTORE
import SwiftUI

struct SoftwareUpdatesSection: View {
    /// The stored choice, the value the update check reads; absent (off) until flipped.
    @AppStorage(UpdateChannel.receiveBetasKey) private var receiveBetas = false

    var body: some View {
        Section("Software Updates") {
            if UpdateChannel.isBetaBuild {
                Text("""
                    This beta checks for new betas. Stable releases are offered too, so when the next stable \
                    version comes out you are moved to it.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Receive beta releases", isOn: $receiveBetas)
                Text("""
                    When enabled, \"Check for Updates\" looks at the beta channel. Beta builds get new features first \
                    but may contain bugs. Turn this off to stay on stable releases only.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
