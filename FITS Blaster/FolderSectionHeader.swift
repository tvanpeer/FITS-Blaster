//
//  FolderSectionHeader.swift
//  FITS Blaster
//

import SwiftUI

struct FolderSectionHeader: View {
    let folderGroup: FolderGroup
    let visibleCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                Image(systemName: "folder")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                Text(folderGroup.folderDisplayName)
                    .scaledFont(size: 10, weight: .bold)
                Text("\(visibleCount)")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
    }
}
