import SwiftUI
import MapKit

/// An always-visible scale bar in the app's units (MapKit's own follows only the phone's region
/// setting, and only appears while zooming).
struct ScaleBar: View {
    let metersPerPoint: Double
    var maxWidth: Double = 110
    @Environment(\.units) private var units

    var body: some View {
        if let bar = units.scaleBar(metersPerPoint: metersPerPoint, maxPoints: maxWidth) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bar.label)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .shadow(color: .white, radius: 1)
                    .shadow(color: .white, radius: 1)
                // A bar with end ticks, outlined in white so it shows on dark and light maps.
                Path { p in
                    let w = bar.points
                    p.move(to: CGPoint(x: 0.75, y: 0)); p.addLine(to: CGPoint(x: 0.75, y: 7))
                    p.move(to: CGPoint(x: 0, y: 6.25)); p.addLine(to: CGPoint(x: w, y: 6.25))
                    p.move(to: CGPoint(x: w - 0.75, y: 0)); p.addLine(to: CGPoint(x: w - 0.75, y: 7))
                }
                .stroke(.black, lineWidth: 1.5)
                .background {
                    Path { p in
                        let w = bar.points
                        p.move(to: CGPoint(x: 0.75, y: 0)); p.addLine(to: CGPoint(x: 0.75, y: 7))
                        p.move(to: CGPoint(x: 0, y: 6.25)); p.addLine(to: CGPoint(x: w, y: 6.25))
                        p.move(to: CGPoint(x: w - 0.75, y: 0)); p.addLine(to: CGPoint(x: w - 0.75, y: 7))
                    }
                    .stroke(.white, lineWidth: 3.5)
                }
                .frame(width: bar.points, height: 7)
            }
            .foregroundStyle(.black)
            .accessibilityElement()
            .accessibilityLabel("Scale: \(bar.label)")
        }
    }
}

/// MapKit's compass button: appears when the map is rotated; tap to point north again.
struct CompassButton: UIViewRepresentable {
    let mapView: MKMapView?

    func makeUIView(context: Context) -> MKCompassButton {
        let button = MKCompassButton(mapView: mapView)
        button.compassVisibility = .adaptive
        return button
    }

    func updateUIView(_ button: MKCompassButton, context: Context) {
        if button.mapView !== mapView { button.mapView = mapView }
    }
}
