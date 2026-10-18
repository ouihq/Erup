import SwiftUI
import UserNotifications

/// Everything Erup told the person, kept so a banner that disappears is never lost, and clearable.
struct NotificationCenterView: View {
    @Environment(ScooterStore.self) private var store
    @State private var confirmsClear = false

    var body: some View {
        List {
            ForEach(store.notices.reversed()) { notice in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: notice.kind == .alert ? "bell.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(notice.kind == .alert ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message).font(.subheadline)
                        Text(notice.date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { store.removeNotice(notice.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove notification")
                }
                .swipeActions {
                    Button(role: .destructive) {
                        withAnimation { store.removeNotice(notice.id) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay {
            if store.notices.isEmpty {
                ContentUnavailableView("No notifications", systemImage: "bell.slash", description: Text("Problems and alerts from your scooter show up here."))
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear all") { confirmsClear = true }
                    .disabled(store.notices.isEmpty)
            }
        }
        .confirmationDialog("Clear all notifications?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                withAnimation { store.clearNotices() }
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
        .onAppear { store.markNoticesRead() }
    }
}

/// The bell in the toolbar, with the number of unread entries.
struct NotificationBell: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        NavigationLink {
            NotificationCenterView()
        } label: {
            Image(systemName: store.notices.isEmpty ? "bell" : "bell.fill")
                .overlay(alignment: .topTrailing) {
                    if store.unreadNoticeCount > 0 {
                        Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: 4, y: -3)
                    }
                }
        }
        .accessibilityLabel(store.unreadNoticeCount > 0 ? "Notifications, \(store.unreadNoticeCount) new" : "Notifications")
    }
}
