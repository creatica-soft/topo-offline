import SwiftUI
import MapKit

/// MapKit's scale bar, always visible (the built-in one only appears while zooming).
/// Uses kilometres/metres or miles/feet according to the phone's region settings.
struct ScaleBar: UIViewRepresentable {
    let mapView: MKMapView?

    func makeUIView(context: Context) -> MKScaleView {
        let view = MKScaleView(mapView: mapView)
        view.scaleVisibility = .visible
        view.legendAlignment = .leading
        return view
    }

    func updateUIView(_ view: MKScaleView, context: Context) {
        if view.mapView !== mapView { view.mapView = mapView }
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
