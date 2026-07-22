import AppKit
import SwiftUI

struct PersistentStoreRecoveryView: View {
    let error: PersistentStoreError

    var body: some View {
        ContentUnavailableView {
            Label(
                error.errorDescription ?? "Local Database Unavailable",
                systemImage: "externaldrive.badge.exclamationmark"
            )
        } description: {
            VStack {
                Text(
                    error.recoverySuggestion
                        ?? "No database files were removed. Copy the entire data folder before attempting recovery."
                )
                if let storeURL = error.storeURL {
                    Text(storeURL.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Database location")
                        .accessibilityValue(storeURL.path(percentEncoded: false))
                }
                Text("Restore a compatible backup or use a compatible version of OpenASO, then reopen the app.")
            }
        } actions: {
            if let storeURL = error.storeURL {
                Button("Show Data Folder", systemImage: "folder") {
                    showDataFolder(containing: storeURL)
                }
            }
            Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                copyDiagnostics()
            }
        }
        .padding()
    }

    private func showDataFolder(containing storeURL: URL) {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([storeURL])
        } else {
            NSWorkspace.shared.open(storeURL.deletingLastPathComponent())
        }
    }

    private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(error.diagnosticReport, forType: .string)
    }
}
