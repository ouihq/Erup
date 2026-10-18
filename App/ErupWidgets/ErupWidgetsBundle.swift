import SwiftUI
import WidgetKit

@main
struct ErupWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScooterStatusWidget()
        ScooterLiveActivity()
        HeadlightControl()
        LockControl()
    }
}
