import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .stock

    enum Tab: Hashable {
        case stock, inbound, outbound, flow, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            StockView()
                .tabItem { Label("库存", systemImage: "shippingbox") }
                .tag(Tab.stock)
            InboundView()
                .tabItem { Label("入库", systemImage: "tray.and.arrow.down") }
                .tag(Tab.inbound)
            OutboundView()
                .tabItem { Label("出库", systemImage: "tray.and.arrow.up") }
                .tag(Tab.outbound)
            FlowView()
                .tabItem { Label("流水", systemImage: "list.bullet.rectangle") }
                .tag(Tab.flow)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .background(PaperBackground())
    }
}
