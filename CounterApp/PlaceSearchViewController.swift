import Contacts
import MapKit
import UIKit

final class PlaceSearchViewController: UITableViewController, UISearchResultsUpdating, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private let searchController = UISearchController(searchResultsController: nil)
    private var results: [MKLocalSearchCompletion] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var didFinish = false

    private let onSelect: (LocalSessionPlaceSnapshot) -> Void
    private let onCancel: () -> Void
    private let onFailure: (Error) -> Void

    init(
        onSelect: @escaping (LocalSessionPlaceSnapshot) -> Void,
        onCancel: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onFailure = onFailure
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search Address or Place"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelSearch)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaceResult")
        tableView.keyboardDismissMode = .onDrag

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Address, landmark, or building"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        DispatchQueue.main.async { [weak self] in
            self?.searchController.searchBar.becomeFirstResponder()
        }
    }

    deinit {
        debounceWorkItem?.cancel()
        completer.cancel()
    }

    func updateSearchResults(for searchController: UISearchController) {
        debounceWorkItem?.cancel()
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            results = []
            tableView.reloadData()
            completer.queryFragment = ""
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.completer.queryFragment = query
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
        tableView.reloadData()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        finishWithFailure(error)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceResult", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        let result = results[indexPath.row]
        content.text = result.title
        content.secondaryText = result.subtitle
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let completion = results[indexPath.row]
        searchController.searchBar.resignFirstResponder()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Searching…", style: .plain, target: nil, action: nil)

        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.address, .pointOfInterest]
        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self else { return }
            if let error {
                self.finishWithFailure(error)
                return
            }
            guard let mapItem = response?.mapItems.first else {
                self.finishWithFailure(NSError(
                    domain: "VoiceSurveyPlaceSearch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No usable place was returned."]
                ))
                return
            }

            let placemark = mapItem.placemark
            let formattedAddress: String? = {
                if let address = placemark.postalAddress {
                    let formatted = CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                    if !formatted.isEmpty { return formatted }
                }
                let fallback = completion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                return fallback.isEmpty ? placemark.title : fallback
            }()
            let label = (mapItem.name ?? completion.title).trimmingCharacters(in: .whitespacesAndNewlines)
            let coordinate = placemark.coordinate
            let snapshot = LocalSessionPlaceSnapshot(
                displayLabel: label.isEmpty ? (formattedAddress ?? "Selected Place") : label,
                formattedAddress: formattedAddress,
                latitude: CLLocationCoordinate2DIsValid(coordinate) ? coordinate.latitude : nil,
                longitude: CLLocationCoordinate2DIsValid(coordinate) ? coordinate.longitude : nil
            )
            self.didFinish = true
            self.dismiss(animated: true) { self.onSelect(snapshot) }
        }
    }

    @objc private func cancelSearch() {
        guard !didFinish else { return }
        didFinish = true
        dismiss(animated: true, completion: onCancel)
    }

    private func finishWithFailure(_ error: Error) {
        guard !didFinish else { return }
        didFinish = true
        dismiss(animated: true) { self.onFailure(error) }
    }
}
