import SwiftUI
#if canImport(MapKit)
import MapKit
#endif
#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteRenderIdentity: Equatable {
    let segments: [[RouteMath.LatLng]]
    let showsEndpoints: Bool
}

/// Segment boundaries are part of the render identity. A missing recording interval is never joined.
struct WorkoutRouteMap: RouteMapRepresentable {
    let segments: [[RouteMath.LatLng]]
    let showsEndpoints: Bool
    init(points: [RouteMath.LatLng], showsEndpoints: Bool = true) {
        segments = points.isEmpty ? [] : [points]
        self.showsEndpoints = showsEndpoints
    }
    init(segments: [[RouteMath.LatLng]], showsEndpoints: Bool = true) {
        self.segments = segments
        self.showsEndpoints = showsEndpoints
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        configure(map, coordinator: context.coordinator)
        return map
    }
    private func configure(_ map: MKMapView, coordinator: Coordinator) {
        guard coordinator.accepts(.init(segments: segments, showsEndpoints: showsEndpoints)) else { return }
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coordinates = segments.filter { $0.count >= 2 }.map { segment in
            segment.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        guard let first = coordinates.first?.first, let last = coordinates.last?.last else { return }
        let lines = coordinates.map { MKPolyline(coordinates: $0, count: $0.count) }
        map.addOverlays(lines)
        if showsEndpoints {
            let start = MKPointAnnotation()
            start.coordinate = first
            start.title = String(localized: "Start")
            let finish = MKPointAnnotation()
            finish.coordinate = last
            finish.title = String(localized: "Finish")
            map.addAnnotations([start, finish])
        }
        guard let firstLine = lines.first else { return }
        let rect = lines.dropFirst().reduce(firstLine.boundingMapRect) { $0.union($1.boundingMapRect) }
        #if canImport(UIKit)
        let padding = UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        #else
        let padding = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        #endif
        map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var renderedIdentity: WorkoutRouteRenderIdentity?
        func accepts(_ identity: WorkoutRouteRenderIdentity) -> Bool {
            guard renderedIdentity != identity else { return false }
            renderedIdentity = identity
            return true
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            #if canImport(UIKit)
            renderer.strokeColor = UIColor(red: 0.08, green: 0.45, blue: 0.96, alpha: 1)
            #else
            renderer.strokeColor = NSColor(red: 0.08, green: 0.45, blue: 0.96, alpha: 1)
            #endif
            renderer.lineWidth = 4
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
    #if canImport(UIKit)
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { configure(map, coordinator: context.coordinator) }
    #else
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map, coordinator: context.coordinator) }
    #endif
}
#else
struct WorkoutRouteMap: View {
    let segments: [[RouteMath.LatLng]]
    init(points: [RouteMath.LatLng], showsEndpoints: Bool = true) { segments = points.isEmpty ? [] : [points] }
    init(segments: [[RouteMath.LatLng]], showsEndpoints: Bool = true) { self.segments = segments }
    var body: some View { Color.clear }
}
#endif
