import Contacts
import MapKit
import UIKit

final class SurveyLocationSettingsViewController: UITableViewController {
    private let store = SavedSurveyLocationStore.shared
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(style: .insetGrouped)
        title = "Location"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? SurveyLocationMode.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Location Mode" : "Saved Survey Locations"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return "Saved locations remain available offline." }
        switch store.mode {
        case .device:
            return "GPS is requested at interview start. The current retry, place-search, and no-GPS fallback flow remains available."
        case .fixed:
            return store.activeLocation == nil
                ? "Choose an active saved location before starting an interview. GPS will not be requested."
                : "GPS and trajectory tracking are disabled. Each interview stores a snapshot of the active location."
        case .none:
            return "GPS and trajectory tracking are disabled. Sessions record that location collection was intentionally disabled."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let mode = SurveyLocationMode.allCases[indexPath.row]
            cell.textLabel?.text = mode.title
            cell.accessoryType = store.mode == mode ? .checkmark : .none
            if mode == .fixed {
                cell.detailTextLabel?.text = store.activeLocation?.name ?? "No fixed location selected"
                cell.detailTextLabel?.textColor = store.activeLocation == nil ? .systemRed : .secondaryLabel
            }
        } else {
            cell.textLabel?.text = "Manage Saved Locations"
            cell.detailTextLabel?.text = store.activeLocation.map { "Active: \($0.name)" }
                ?? "Add, edit, delete, or select a location"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            navigationController?.pushViewController(
                SavedLocationsViewController(onChange: { [weak self] in self?.onChange() }),
                animated: true
            )
            return
        }
        let mode = SurveyLocationMode.allCases[indexPath.row]
        if mode == .fixed, store.activeLocation == nil {
            let alert = UIAlertController(
                title: "Choose a Fixed Location",
                message: "Add or select a saved survey location before enabling Fixed Survey Location.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Manage Locations", style: .default) { [weak self] _ in
                self?.navigationController?.pushViewController(
                    SavedLocationsViewController(onChange: { [weak self] in self?.onChange() }),
                    animated: true
                )
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
            return
        }
        store.mode = mode
        onChange()
        tableView.reloadData()
    }
}

final class SavedLocationsViewController: UITableViewController {
    private let store = SavedSurveyLocationStore.shared
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(style: .insetGrouped)
        title = "Saved Locations"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addLocation)
        )
        if let message = store.loadErrorDescription { showError(message) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(store.sortedLocations.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "The active location appears first, followed by recently used locations. There is no fixed limit."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let values = store.sortedLocations
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard !values.isEmpty else {
            cell.textLabel?.text = "No saved locations"
            cell.detailTextLabel?.text = "Tap + to search Apple Maps or enter one manually."
            cell.selectionStyle = .none
            return cell
        }
        let location = values[indexPath.row]
        cell.textLabel?.text = location.name
        cell.detailTextLabel?.text = location.formattedAddress
            ?? (location.hasValidCoordinate ? "\(location.latitude!), \(location.longitude!)" : "No address or coordinate")
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessoryType = store.activeLocationId == location.id ? .checkmark : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let values = store.sortedLocations
        guard !values.isEmpty else { return }
        presentActions(for: values[indexPath.row])
    }

    @objc private func addLocation() {
        let alert = UIAlertController(title: "Add Location", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Search Apple Maps", style: .default) { [weak self] _ in
            self?.showSearch()
        })
        alert.addAction(UIAlertAction(title: "Enter Manually", style: .default) { [weak self] _ in
            self?.showManualEditor(location: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    private func presentActions(for location: SavedSurveyLocation) {
        let alert = UIAlertController(title: location.name, message: location.formattedAddress, preferredStyle: .actionSheet)
        if store.activeLocationId != location.id {
            alert.addAction(UIAlertAction(title: "Set as Active Fixed Location", style: .default) { [weak self] _ in
                guard let self else { return }
                self.store.select(id: location.id)
                self.onChange()
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in
            self?.showManualEditor(location: location)
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.confirmDelete(location)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func confirmDelete(_ location: SavedSurveyLocation) {
        let isActive = store.activeLocationId == location.id
        let message = isActive
            ? "This is the active fixed location. Deleting it will leave Fixed Survey Location invalid until another location or mode is chosen. Past sessions will remain unchanged."
            : "Past sessions that used this location will remain unchanged."
        let alert = UIAlertController(title: "Delete \(location.name)?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.delete(id: location.id)
                self.onChange()
                self.tableView.reloadData()
            } catch { self.showError(error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    private func showSearch() {
        let search = SavedLocationSearchViewController(
            biasCoordinate: store.activeLocation.flatMap(Self.coordinate)
                ?? TrajectoryTracker.shared.lastKnownCoordinate,
            onResolved: { [weak self] mapItem in self?.showConfirmation(mapItem) },
            onManualEntry: { [weak self] in self?.showManualEditor(location: nil) }
        )
        navigationController?.pushViewController(search, animated: true)
    }

    private func showConfirmation(_ mapItem: MKMapItem) {
        let controller = LocationConfirmationViewController(mapItem: mapItem) { [weak self] candidate in
            self?.save(candidate, makeActive: true)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func showManualEditor(location: SavedSurveyLocation?) {
        navigationController?.pushViewController(
            ManualSurveyLocationViewController(location: location) { [weak self] candidate in
                self?.save(candidate, makeActive: location == nil)
            },
            animated: true
        )
    }

    private func save(_ candidate: SavedSurveyLocation, makeActive: Bool) {
        let commit = { [weak self] in
            guard let self else { return }
            do {
                try self.store.save(candidate, makeActive: makeActive)
                if makeActive { self.store.mode = .fixed }
                self.onChange()
                self.navigationController?.popToViewController(self, animated: true)
                self.tableView.reloadData()
            } catch { self.showError(error.localizedDescription) }
        }
        if let duplicate = store.duplicateCandidate(for: candidate) {
            let alert = UIAlertController(
                title: "Possible Duplicate",
                message: "This appears similar to \(duplicate.name). Save it anyway?",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save Anyway", style: .default) { _ in commit() })
            present(alert, animated: true)
        } else { commit() }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Location Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private static func coordinate(_ location: SavedSurveyLocation) -> CLLocationCoordinate2D? {
        guard location.hasValidCoordinate, let lat = location.latitude, let lon = location.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

final class SavedLocationSearchViewController: UITableViewController, UISearchResultsUpdating, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private let searchController = UISearchController(searchResultsController: nil)
    private var results: [MKLocalSearchCompletion] = []
    private let onResolved: (MKMapItem) -> Void
    private let onManualEntry: () -> Void
    private var errorMessage: String?

    init(
        biasCoordinate: CLLocationCoordinate2D?,
        onResolved: @escaping (MKMapItem) -> Void,
        onManualEntry: @escaping () -> Void
    ) {
        self.onResolved = onResolved
        self.onManualEntry = onManualEntry
        super.init(style: .insetGrouped)
        if let biasCoordinate {
            completer.region = MKCoordinateRegion(
                center: biasCoordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search Apple Maps"
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Place or street address"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Manual",
            style: .plain,
            target: self,
            action: #selector(manualEntry)
        )
    }

    deinit { completer.cancel() }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        errorMessage = nil
        completer.queryFragment = query
        if query.isEmpty { results = []; tableView.reloadData() }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        errorMessage = nil
        results = completer.results
        tableView.reloadData()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        errorMessage = "Apple Maps search is unavailable. Check the connection or enter the location manually."
        results = []
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        errorMessage == nil ? results.count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if let errorMessage {
            cell.textLabel?.text = "Search Unavailable"
            cell.detailTextLabel?.text = errorMessage
            cell.detailTextLabel?.numberOfLines = 0
            cell.selectionStyle = .none
        } else {
            let result = results[indexPath.row]
            cell.textLabel?.text = result.title
            cell.detailTextLabel?.text = result.subtitle
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard errorMessage == nil else { return }
        let completion = results[indexPath.row]
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        navigationItem.rightBarButtonItem?.isEnabled = false
        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self else { return }
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            if let error {
                self.showSearchError(error.localizedDescription)
                return
            }
            let mapItems = response?.mapItems ?? []
            guard !mapItems.isEmpty else {
                self.showSearchError("No matching place was found.")
                return
            }
            if mapItems.count == 1 {
                self.onResolved(mapItems[0])
            } else {
                self.presentResultChoice(mapItems)
            }
        }
    }

    private func presentResultChoice(_ mapItems: [MKMapItem]) {
        let chooser = UIAlertController(
            title: "Choose the Exact Place",
            message: "Apple Maps returned more than one match.",
            preferredStyle: .actionSheet
        )
        for item in mapItems.prefix(10) {
            let address = SurveyLocationAddressFormatter.address(for: item)
            chooser.addAction(UIAlertAction(title: [item.name, address].compactMap { $0 }.joined(separator: " — "), style: .default) { [weak self] _ in
                self?.onResolved(item)
            })
        }
        chooser.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = chooser.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(chooser, animated: true)
    }

    private func showSearchError(_ message: String) {
        let alert = UIAlertController(title: "Search Failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Enter Manually", style: .default) { [weak self] _ in self?.manualEntry() })
        present(alert, animated: true)
    }

    @objc private func manualEntry() { onManualEntry() }
}

final class LocationConfirmationViewController: UIViewController {
    private let candidate: SurveyLocationAddressCandidate
    private let suggestedName: String?
    private let original: SavedSurveyLocation?
    private let onSave: (SavedSurveyLocation) -> Void
    private let onCancel: (() -> Void)?
    private let saveButtonTitle: String
    private let nameField = UITextField()
    private let mapView = MKMapView()

    init(
        mapItem: MKMapItem,
        original: SavedSurveyLocation? = nil,
        onCancel: (() -> Void)? = nil,
        saveButtonTitle: String = "Save and Use as Fixed Location",
        onSave: @escaping (SavedSurveyLocation) -> Void
    ) {
        let coordinate = mapItem.placemark.coordinate
        self.candidate = SurveyLocationAddressCandidate(
            name: mapItem.name,
            formattedAddress: SurveyLocationAddressFormatter.address(for: mapItem) ?? mapItem.name ?? "Selected location",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            mapItemIdentifier: mapItem.identifier?.rawValue
        )
        suggestedName = nil
        self.original = original
        self.onCancel = onCancel
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = "Confirm Location"
    }

    init(
        candidate: SurveyLocationAddressCandidate,
        suggestedName: String?,
        original: SavedSurveyLocation? = nil,
        onCancel: (() -> Void)? = nil,
        saveButtonTitle: String = "Save and Use as Fixed Location",
        onSave: @escaping (SavedSurveyLocation) -> Void
    ) {
        self.candidate = candidate
        self.suggestedName = suggestedName
        self.original = original
        self.onCancel = onCancel
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = "Confirm Address"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if onCancel != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancel)
            )
        }
        let address = candidate.formattedAddress
        nameField.borderStyle = .roundedRect
        nameField.text = suggestedName ?? candidate.name ?? address
        nameField.placeholder = "Location name"

        let addressLabel = UILabel()
        addressLabel.text = address
        addressLabel.numberOfLines = 0
        addressLabel.textColor = .secondaryLabel

        mapView.heightAnchor.constraint(equalToConstant: 280).isActive = true
        let coordinate = CLLocationCoordinate2D(latitude: candidate.latitude, longitude: candidate.longitude)
        let annotation = MKPointAnnotation()
        annotation.title = candidate.name ?? suggestedName
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)
        mapView.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: false)

        let saveButton = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = saveButtonTitle
        saveButton.configuration = configuration
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [nameField, addressLabel, mapView, saveButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])
    }

    @objc private func save() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        let now = Date()
        if let original {
            onSave(original.resolved(with: candidate, confirmedName: name, at: now))
        } else {
            onSave(SavedSurveyLocation(
                id: UUID(),
                name: name,
                formattedAddress: candidate.formattedAddress,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                mapItemIdentifier: candidate.mapItemIdentifier,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: nil
            ))
        }
    }

    @objc private func cancel() { onCancel?() }
}

final class ManualSurveyLocationViewController: UIViewController {
    private let original: SavedSurveyLocation?
    private let onSave: (SavedSurveyLocation) -> Void
    private let nameField = UITextField()
    private let addressField = UITextField()
    private let latitudeField = UITextField()
    private let longitudeField = UITextField()
    private let addressResolver: SurveyLocationAddressResolving
    private let saveButton = UIButton(type: .system)

    init(
        location: SavedSurveyLocation?,
        addressResolver: SurveyLocationAddressResolving = MapKitSurveyLocationAddressResolver(),
        onSave: @escaping (SavedSurveyLocation) -> Void
    ) {
        original = location
        self.addressResolver = addressResolver
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = location == nil ? "Enter Location" : "Edit Location"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configure(nameField, placeholder: "Location name (required)", text: original?.name)
        configure(addressField, placeholder: "Address", text: original?.formattedAddress)
        configure(latitudeField, placeholder: "Latitude (optional)", text: original?.latitude.map { String($0) })
        configure(longitudeField, placeholder: "Longitude (optional)", text: original?.longitude.map { String($0) })
        latitudeField.keyboardType = .numbersAndPunctuation
        longitudeField.keyboardType = .numbersAndPunctuation

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Resolve Address and Save"
        saveButton.configuration = configuration
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [nameField, addressField, latitudeField, longitudeField, saveButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])
    }

    private func configure(_ field: UITextField, placeholder: String, text: String?) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.text = text
        field.autocorrectionType = .no
    }

    @objc private func save() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { showError("Enter a location name."); return }
        let latitude = parsedCoordinate(latitudeField.text, range: -90...90, label: "latitude")
        let longitude = parsedCoordinate(longitudeField.text, range: -180...180, label: "longitude")
        guard latitude.valid, longitude.valid else { return }
        guard (latitude.value == nil) == (longitude.value == nil) else {
            showError("Enter both latitude and longitude, or leave both blank so the typed address can be resolved.")
            return
        }
        let address = nonEmpty(addressField.text)
        if latitude.value == nil, let address {
            resolveTypedAddress(name: name, address: address)
            return
        }
        commitLocation(
            name: name,
            address: address,
            latitude: latitude.value,
            longitude: longitude.value,
            mapItemIdentifier: latitude.value == nil ? nil : original?.mapItemIdentifier
        )
    }

    private func resolveTypedAddress(name: String, address: String) {
        saveButton.isEnabled = false
        saveButton.configuration?.showsActivityIndicator = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await ManualSurveyLocationAddressResolution.resolve(
                typedAddress: address,
                using: self.addressResolver
            )
            self.saveButton.isEnabled = true
            self.saveButton.configuration?.showsActivityIndicator = false
            switch outcome {
            case let .candidates(candidates):
                self.presentAddressCandidates(candidates, typedName: name)
            case .addressOnly:
                self.offerAddressOnlySave(name: name, address: address)
            }
        }
    }

    private func presentAddressCandidates(_ candidates: [SurveyLocationAddressCandidate], typedName: String) {
        if candidates.count == 1, let candidate = candidates.first {
            showAddressConfirmation(candidate, typedName: typedName)
            return
        }
        let chooser = UIAlertController(
            title: "Choose the Exact Address",
            message: "The typed street address matched more than one MapKit result. Nothing will be selected automatically.",
            preferredStyle: .actionSheet
        )
        for candidate in candidates.prefix(10) {
            let title = [candidate.name, candidate.formattedAddress]
                .compactMap { $0 }
                .joined(separator: " — ")
            chooser.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.showAddressConfirmation(candidate, typedName: typedName)
            })
        }
        chooser.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        if let popover = chooser.popoverPresentationController {
            popover.sourceView = saveButton
            popover.sourceRect = saveButton.bounds
        }
        present(chooser, animated: true)
    }

    private func showAddressConfirmation(_ candidate: SurveyLocationAddressCandidate, typedName: String) {
        navigationController?.pushViewController(
            LocationConfirmationViewController(
                candidate: candidate,
                suggestedName: typedName,
                original: original,
                onSave: onSave
            ),
            animated: true
        )
    }

    private func offerAddressOnlySave(name: String, address: String) {
        let alert = UIAlertController(
            title: "Map Coordinates Unavailable",
            message: "The typed address could not be resolved right now. You can still save it for offline use; dashboards will show the name and address without a map pin.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save Address Only", style: .default) { [weak self] _ in
            self?.commitLocation(
                name: name,
                address: address,
                latitude: nil,
                longitude: nil,
                mapItemIdentifier: nil
            )
        })
        present(alert, animated: true)
    }

    private func commitLocation(
        name: String,
        address: String?,
        latitude: Double?,
        longitude: Double?,
        mapItemIdentifier: String?
    ) {
        let now = Date()
        onSave(SavedSurveyLocation(
            id: original?.id ?? UUID(),
            name: name,
            formattedAddress: address,
            latitude: latitude,
            longitude: longitude,
            mapItemIdentifier: mapItemIdentifier,
            createdAt: original?.createdAt ?? now,
            updatedAt: now,
            lastUsedAt: original?.lastUsedAt
        ))
    }

    private func parsedCoordinate(_ text: String?, range: ClosedRange<Double>, label: String) -> (value: Double?, valid: Bool) {
        guard let text = nonEmpty(text) else { return (nil, true) }
        guard let value = Double(text), range.contains(value) else {
            showError("Enter a valid \(label) between \(range.lowerBound) and \(range.upperBound).")
            return (nil, false)
        }
        return (value, true)
    }

    private func nonEmpty(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Invalid Location", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

@MainActor
enum SessionLocationRetryPresenter {
    static func resolveIfNeeded(
        in sessionDirectoryURL: URL,
        from presenter: UIViewController,
        resolver: SurveyLocationAddressResolving = MapKitSurveyLocationAddressResolver(),
        completion: @escaping (Bool) -> Void
    ) {
        let manifest: LocalSessionManifest
        do {
            manifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
        } catch {
            showPersistenceError(error, from: presenter, completion: completion)
            return
        }
        guard let locationInfo = manifest.locationInfo,
              locationInfo.needsCoordinateResolutionOnRetry,
              let address = locationInfo.formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            completion(true)
            return
        }

        let progress = UIAlertController(
            title: "Finding Session Map Point",
            message: "This saved session has an address but no coordinates. Searching Apple Maps before retrying processing...",
            preferredStyle: .alert
        )
        presenter.present(progress, animated: true)
        Task {
            let outcome = await ManualSurveyLocationAddressResolution.resolve(
                typedAddress: address,
                using: resolver
            )
            progress.dismiss(animated: true) {
                handle(
                    outcome,
                    locationInfo: locationInfo,
                    sessionDirectoryURL: sessionDirectoryURL,
                    presenter: presenter,
                    resolver: resolver,
                    completion: completion
                )
            }
        }
    }

    private static func handle(
        _ outcome: ManualAddressResolutionOutcome,
        locationInfo: SessionLocationInfo,
        sessionDirectoryURL: URL,
        presenter: UIViewController,
        resolver: SurveyLocationAddressResolving,
        completion: @escaping (Bool) -> Void
    ) {
        switch outcome {
        case let .candidates(candidates):
            if candidates.count == 1, let candidate = candidates.first {
                confirm(
                    candidate,
                    locationInfo: locationInfo,
                    sessionDirectoryURL: sessionDirectoryURL,
                    presenter: presenter,
                    completion: completion
                )
                return
            }
            let chooser = UIAlertController(
                title: "Choose the Session Address",
                message: "Apple Maps found more than one match. Select and confirm the point that belongs to this saved interview.",
                preferredStyle: .actionSheet
            )
            for candidate in candidates.prefix(10) {
                let title = [candidate.name, candidate.formattedAddress]
                    .compactMap { $0 }
                    .joined(separator: " — ")
                chooser.addAction(UIAlertAction(title: title, style: .default) { _ in
                    confirm(
                        candidate,
                        locationInfo: locationInfo,
                        sessionDirectoryURL: sessionDirectoryURL,
                        presenter: presenter,
                        completion: completion
                    )
                })
            }
            chooser.addAction(UIAlertAction(title: "Cancel Retry", style: .cancel) { _ in
                completion(false)
            })
            if let popover = chooser.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            presenter.present(chooser, animated: true)
        case .addressOnly:
            let alert = UIAlertController(
                title: "Session Map Point Still Unavailable",
                message: "Apple Maps could not resolve the saved address. You can try again, continue processing without a map point, or cancel this retry.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in
                resolveIfNeeded(
                    in: sessionDirectoryURL,
                    from: presenter,
                    resolver: resolver,
                    completion: completion
                )
            })
            alert.addAction(UIAlertAction(title: "Continue Without Map Point", style: .default) { _ in
                completion(true)
            })
            alert.addAction(UIAlertAction(title: "Cancel Retry", style: .cancel) { _ in
                completion(false)
            })
            presenter.present(alert, animated: true)
        }
    }

    private static func confirm(
        _ candidate: SurveyLocationAddressCandidate,
        locationInfo: SessionLocationInfo,
        sessionDirectoryURL: URL,
        presenter: UIViewController,
        completion: @escaping (Bool) -> Void
    ) {
        let now = Date()
        let original = SavedSurveyLocation(
            id: locationInfo.savedLocationId ?? UUID(),
            name: locationInfo.locationName ?? candidate.name ?? "Survey location",
            formattedAddress: locationInfo.formattedAddress,
            latitude: nil,
            longitude: nil,
            mapItemIdentifier: nil,
            createdAt: now,
            updatedAt: now,
            lastUsedAt: nil
        )
        let controller = LocationConfirmationViewController(
            candidate: candidate,
            suggestedName: locationInfo.locationName,
            original: original,
            onCancel: {
                presenter.dismiss(animated: true) { completion(false) }
            },
            saveButtonTitle: "Save Point and Retry Session",
            onSave: { resolved in
                do {
                    try LocalSessionManifestStore.resolveFixedLocationForRetry(
                        in: sessionDirectoryURL,
                        candidate: candidate,
                        confirmedName: resolved.name
                    )
                    updateSavedLocationIfPresent(
                        id: locationInfo.savedLocationId,
                        candidate: candidate,
                        confirmedName: resolved.name
                    )
                    presenter.dismiss(animated: true) { completion(true) }
                } catch {
                    presenter.dismiss(animated: true) {
                        showPersistenceError(error, from: presenter, completion: completion)
                    }
                }
            }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        presenter.present(navigation, animated: true)
    }

    private static func updateSavedLocationIfPresent(
        id: UUID?,
        candidate: SurveyLocationAddressCandidate,
        confirmedName: String
    ) {
        guard let id,
              let saved = SavedSurveyLocationStore.shared.locations.first(where: { $0.id == id }) else { return }
        try? SavedSurveyLocationStore.shared.save(
            saved.resolved(with: candidate, confirmedName: confirmedName)
        )
    }

    private static func showPersistenceError(
        _ error: Error,
        from presenter: UIViewController,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(
            title: "Session Location Could Not Be Saved",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(false) })
        presenter.present(alert, animated: true)
    }
}

final class MapKitSurveyLocationAddressResolver: SurveyLocationAddressResolving {
    func candidates(forTypedAddress address: String) async throws -> [SurveyLocationAddressCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.resultTypes = [.address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate),
                  let formattedAddress = SurveyLocationAddressFormatter.address(for: item) else {
                return nil
            }
            return SurveyLocationAddressCandidate(
                name: item.name,
                formattedAddress: formattedAddress,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                mapItemIdentifier: item.identifier?.rawValue
            )
        }
    }
}

enum SurveyLocationAddressFormatter {
    static func address(for mapItem: MKMapItem) -> String? {
        if let postalAddress = mapItem.placemark.postalAddress {
            let value = CNPostalAddressFormatter.string(from: postalAddress, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let value = mapItem.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
