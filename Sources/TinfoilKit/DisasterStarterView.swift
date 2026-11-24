import Foundation
import SwiftUI

struct DisasterStarterView: View {
    var body: some View {
        List {
            Section("Get to safety") {
                Text("If the ground is shaking, drop, cover and hold on. Protect your head and neck. If you use a wheelchair, lock the wheels if you can, then cover and hold on.")
                Text("Once shaking stops, stay clear of damaged buildings, downed wires and floodwater. Expect aftershocks. In the U.S., call 911 for immediate danger or serious injury.")
                Text("In a low-lying coastal area, strong or prolonged shaking, a sudden change in sea level or a loud ocean roar can signal a tsunami. As soon as you can move safely, follow evacuation signs or head inland or to high ground.")
            }
            Section("Find your bearings") {
                Text("Note the time and your location using a street intersection, landmark or coordinates. Use your household meeting point if you can reach it safely.")
                Text("Use saved maps to orient yourself. Check local evacuation orders, road and bridge conditions and utility advisories. Turn back if a route looks unsafe.")
            }
            Section("Check in") {
                Text("Text your household or a contact outside the affected area. Keep it short so they can pass it on.")
                Text("Name · time · location · safe or need help · next check-in")
                    .font(.callout)
            }
            Section("Get local updates") {
                Text("Follow local emergency alerts and posted instructions. If you lose phone service, listen for updates on a battery-powered radio if one is available.")
            }
            Section("Official sources · online") {
                Link("FEMA earthquake safety", destination: Self.earthquakeSafety)
                Link("CDC safety after an earthquake", destination: Self.afterEarthquake)
                Link("National Weather Service tsunami guidance", destination: Self.tsunamiSafety)
                Link("FEMA household communication planning", destination: Self.communicationPlanning)
                Link("FEMA alerts and warnings", destination: Self.emergencyAlerts)
            }
        }
        .navigationTitle("Disaster starter guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let earthquakeSafety = URL(
        string: "https://www.ready.gov/sites/default/files/2025-02/fema_full-suite-hazard-info-sheets.pdf"
    )!
    private static let afterEarthquake = URL(
        string: "https://www.cdc.gov/earthquakes/safety/stay-safe-after-an-earthquake.html"
    )!
    private static let tsunamiSafety = URL(string: "https://www.weather.gov/safety/tsunami-during")!
    private static let communicationPlanning = URL(string: "https://www.fema.gov/print/pdf/node/331794")!
    private static let emergencyAlerts = URL(
        string: "https://www.fema.gov/sites/default/files/documents/fema_hm-know-your-alerts-and-warnings_english.pdf"
    )!
}
