import UIKit
import MapKit
import CoreLocation

final class MapViewController: UIViewController {

    private let mapView = MKMapView()
    private let locationManager = CLLocationManager()
    private let statusLabel = UILabel()
    private let buttonStack = UIStackView()
    private var hasCenteredOnUser = false
    private var latestLocation: CLLocation?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Your location"
        navigationItem.largeTitleDisplayMode = .never

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.delegate = self

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Requesting location access…"

        let recenter = makePrimaryButton(title: "Recenter", color: .secondaryLabel)
        recenter.configuration?.baseBackgroundColor = .secondarySystemFill
        recenter.addTarget(self, action: #selector(recenterTapped), for: .touchUpInside)

        let continueBtn = makePrimaryButton(title: "Continue to survey", color: .systemBlue)
        continueBtn.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)

        buttonStack.axis = .vertical
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(recenter)
        buttonStack.addArrangedSubview(continueBtn)

        view.addSubview(mapView)
        view.addSubview(statusLabel)
        view.addSubview(buttonStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: guide.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            buttonStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // If permission was already granted earlier, ensure we start tracking immediately.
        if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
            mapView.setUserTrackingMode(.follow, animated: true)
        }
    }

    private func makePrimaryButton(title: String, color: UIColor) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = color
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        return button
    }

    @objc private func recenterTapped() {
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    @objc private func continueTapped() {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        guard let voiceVC = storyboard.instantiateViewController(withIdentifier: "VoiceSurveyVC") as? ViewController else {
            return
        }
        voiceVC.mapLocationPrefill = makeMapLocationPayload()
        navigationController?.pushViewController(voiceVC, animated: true)
    }

    private func makeMapLocationPayload() -> MapLocationPayload? {
        let loc = latestLocation ?? mapView.userLocation.location
        guard let loc else { return nil }
        guard loc.horizontalAccuracy >= 0 else { return nil }
        let c = loc.coordinate
        guard CLLocationCoordinate2DIsValid(c) else { return nil }
        let acc = loc.horizontalAccuracy
        return MapLocationPayload(
            latitude: c.latitude,
            longitude: c.longitude,
            horizontalAccuracyMeters: acc.isFinite && acc >= 0 ? acc : nil
        )
    }
}

// MARK: - MKMapViewDelegate

extension MapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
        if mode == .none {
            statusLabel.text = "Map not following you — tap Recenter to follow GPS."
        } else {
            statusLabel.text = "Following your location (GPS)."
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension MapViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
            mapView.setUserTrackingMode(.follow, animated: true)
            statusLabel.text = "Following your location (GPS)."
        case .denied, .restricted:
            statusLabel.text = "Location off — enable in Settings to show your position on the map."
            mapView.setUserTrackingMode(.none, animated: false)
        case .notDetermined:
            statusLabel.text = "Waiting for location permission…"
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        latestLocation = latest
        statusLabel.text = "Location acquired."

        guard !hasCenteredOnUser else { return }
        hasCenteredOnUser = true

        let region = MKCoordinateRegion(
            center: latest.coordinate,
            latitudinalMeters: 1500,
            longitudinalMeters: 1500
        )
        mapView.setRegion(region, animated: true)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusLabel.text = "Couldn’t get location: \(error.localizedDescription)"
    }
}
