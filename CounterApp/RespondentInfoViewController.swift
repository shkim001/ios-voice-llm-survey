import UIKit

class RespondentInfoViewController: UIViewController {
    
    // MARK: - Properties
    var onInfoSubmitted: ((RespondentInfo) -> Void)?
    var onCancel: (() -> Void)?
    var initialSurveyLocation: String?
    private var activeTextField: UITextField?
    private let ageRanges = ["Under 18", "18-24", "25-34", "35-44", "45-54", "55-64", "65+"]
    private let raceOptions = [
        "American Indian or Alaska Native",
        "Asian",
        "Black or African American",
        "Hispanic, Latino, or Spanish origin",
        "Middle Eastern or North African",
        "Native Hawaiian or Other Pacific Islander",
        "White"
    ]
    private var selectedAgeRangeIndex: Int?
    private var selectedRaceIndex: Int?
    private var isAnonymousSurvey = true
    
    // MARK: - UI Elements
    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        return scrollView
    }()
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.distribution = .fill
        stackView.alignment = .fill
        return stackView
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Respondent Information"
        label.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.textColor = .label
        return label
    }()
    
    private let nameTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Name"
        textField.borderStyle = .roundedRect
        textField.font = UIFont.systemFont(ofSize: 16)
        return textField
    }()

    private let anonymousButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Anonymous survey", for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.contentHorizontalAlignment = .leading
        button.tintColor = .systemBlue
        button.setImage(UIImage(systemName: "square"), for: .normal)
        button.configuration = nil
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        return button
    }()
    
    private let ageRangeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.setTitle("Select age range", for: .normal)
        button.setTitleColor(.placeholderText, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return button
    }()
    
    private let genderSegmentedControl: UISegmentedControl = {
        let items = ["Male", "Female", "Other", "Prefer not"]
        let control = UISegmentedControl(items: items)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        return control
    }()
    
    private let emailTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Email (optional)"
        textField.borderStyle = .roundedRect
        textField.font = UIFont.systemFont(ofSize: 16)
        textField.keyboardType = .emailAddress
        textField.textContentType = .emailAddress
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .next
        return textField
    }()

    private let raceButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.setTitle("Select race", for: .normal)
        button.setTitleColor(.placeholderText, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        button.titleLabel?.numberOfLines = 0
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return button
    }()
    
    private let locationTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Survey Location"
        textField.borderStyle = .roundedRect
        textField.font = UIFont.systemFont(ofSize: 16)
        return textField
    }()
    
    private let submitButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Start Recording", for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        return button
    }()

    private lazy var nameLabel = createLabel(text: "Name *")
    private lazy var ageLabel = createLabel(text: "Age range *")
    private lazy var emailLabel = createLabel(text: "Email (optional)")
    private lazy var raceLabel = createLabel(text: "Race *")
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
        setupKeyboardObservers()
        setupTextFieldDelegates()
        updateAnonymousSurveyUI()
        applyInitialSurveyLocation()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeKeyboardObservers()
    }
    
    deinit {
        removeKeyboardObservers()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        // Set navigation bar
        title = "Respondent Info"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelButtonTapped)
        )
        
        // Add subviews
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)
        
        // Add labels and fields to stack view
        let genderLabel = createLabel(text: "Gender *")
        let locationLabel = createLabel(text: "Survey Location *")
        
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(anonymousButton)
        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(nameTextField)
        stackView.addArrangedSubview(ageLabel)
        stackView.addArrangedSubview(ageRangeButton)
        stackView.addArrangedSubview(genderLabel)
        stackView.addArrangedSubview(genderSegmentedControl)
        stackView.addArrangedSubview(raceLabel)
        stackView.addArrangedSubview(raceButton)
        stackView.addArrangedSubview(emailLabel)
        stackView.addArrangedSubview(emailTextField)
        stackView.addArrangedSubview(locationLabel)
        stackView.addArrangedSubview(locationTextField)
        stackView.addArrangedSubview(submitButton)
        
        // Add button action
        submitButton.addTarget(self, action: #selector(submitButtonTapped), for: .touchUpInside)
        anonymousButton.addTarget(self, action: #selector(anonymousButtonTapped), for: .touchUpInside)
        ageRangeButton.addTarget(self, action: #selector(ageRangeButtonTapped), for: .touchUpInside)
        raceButton.addTarget(self, action: #selector(raceButtonTapped), for: .touchUpInside)
        
        // Add tap gesture to dismiss keyboard
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }
    
    private func setupTextFieldDelegates() {
        nameTextField.delegate = self
        emailTextField.delegate = self
        locationTextField.delegate = self
    }

    private func applyInitialSurveyLocation() {
        let value = initialSurveyLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            locationTextField.text = value
        }
    }
    
    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let activeTextField = activeTextField else {
            return
        }
        
        let keyboardHeight = keyboardFrame.height
        let contentInsets = UIEdgeInsets(top: 0, left: 0, bottom: keyboardHeight, right: 0)
        
        scrollView.contentInset = contentInsets
        scrollView.scrollIndicatorInsets = contentInsets
        
        // Calculate the rect of the active text field
        var aRect = view.frame
        aRect.size.height -= keyboardHeight
        
        let textFieldRect = activeTextField.convert(activeTextField.bounds, to: scrollView)
        let textFieldBottom = textFieldRect.origin.y + textFieldRect.size.height
        
        // Add some padding
        let padding: CGFloat = 20
        
        if textFieldBottom > aRect.size.height - padding {
            let scrollPoint = CGPoint(x: 0, y: textFieldBottom - aRect.size.height + padding)
            scrollView.setContentOffset(scrollPoint, animated: true)
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        let contentInsets = UIEdgeInsets.zero
        scrollView.contentInset = contentInsets
        scrollView.scrollIndicatorInsets = contentInsets
    }
    
    private func createLabel(text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = .label
        return label
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            
            nameTextField.heightAnchor.constraint(equalToConstant: 44),
            ageRangeButton.heightAnchor.constraint(equalToConstant: 44),
            genderSegmentedControl.heightAnchor.constraint(equalToConstant: 32),
            raceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            emailTextField.heightAnchor.constraint(equalToConstant: 44),
            locationTextField.heightAnchor.constraint(equalToConstant: 44),
            submitButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    // MARK: - Actions
    @objc private func submitButtonTapped() {
        let nameText = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailText = emailTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard isAnonymousSurvey || !nameText.isEmpty else {
            showAlert(message: "Please enter name")
            return
        }

        guard let selectedAgeRangeIndex else {
            showAlert(message: "Please select age range")
            return
        }

        guard let selectedRaceIndex else {
            showAlert(message: "Please select race")
            return
        }
        
        guard emailText.isEmpty || InterviewerProfile.isValidEmail(emailText) else {
            showAlert(message: "Please enter a valid email or leave it blank")
            return
        }
        
        guard let location = locationTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else {
            showAlert(message: "Please enter survey location")
            return
        }
        
        let genderOptions = ["Male", "Female", "Other", "Prefer not to say"]
        let gender = genderOptions[genderSegmentedControl.selectedSegmentIndex]
        let ageRange = ageRanges[selectedAgeRangeIndex]
        let race = raceOptions[selectedRaceIndex]
        
        let info = RespondentInfo(
            isAnonymous: isAnonymousSurvey,
            name: isAnonymousSurvey ? nil : nameText,
            age: nil,
            ageRange: ageRange,
            gender: gender,
            race: race,
            email: isAnonymousSurvey || emailText.isEmpty
                ? nil
                : InterviewerProfile.normalizedEmail(emailText),
            location: location
        )
        
        onInfoSubmitted?(info)
    }
    
    @objc private func cancelButtonTapped() {
        onCancel?()
    }
    
    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func anonymousButtonTapped() {
        isAnonymousSurvey.toggle()
        updateAnonymousSurveyUI()
    }

    @objc private func ageRangeButtonTapped() {
        showOptionPicker(
            title: "Age Range",
            options: ageRanges,
            selectedIndex: selectedAgeRangeIndex
        ) { [weak self] index in
            self?.selectedAgeRangeIndex = index
            self?.updateSelectionButtons()
        }
    }

    @objc private func raceButtonTapped() {
        showOptionPicker(
            title: "Race",
            options: raceOptions,
            selectedIndex: selectedRaceIndex
        ) { [weak self] index in
            self?.selectedRaceIndex = index
            self?.updateSelectionButtons()
        }
    }

    private func updateAnonymousSurveyUI() {
        anonymousButton.setImage(
            UIImage(systemName: isAnonymousSurvey ? "checkmark.square.fill" : "square"),
            for: .normal
        )

        nameLabel.isHidden = isAnonymousSurvey
        nameTextField.isHidden = isAnonymousSurvey
        emailLabel.isHidden = isAnonymousSurvey
        emailTextField.isHidden = isAnonymousSurvey

        if isAnonymousSurvey {
            nameTextField.text = nil
            emailTextField.text = nil
            activeTextField?.resignFirstResponder()
        }
    }

    private func updateSelectionButtons() {
        if let selectedAgeRangeIndex {
            ageRangeButton.setTitle(ageRanges[selectedAgeRangeIndex], for: .normal)
            ageRangeButton.setTitleColor(.label, for: .normal)
        } else {
            ageRangeButton.setTitle("Select age range", for: .normal)
            ageRangeButton.setTitleColor(.placeholderText, for: .normal)
        }

        if let selectedRaceIndex {
            raceButton.setTitle(raceOptions[selectedRaceIndex], for: .normal)
            raceButton.setTitleColor(.label, for: .normal)
        } else {
            raceButton.setTitle("Select race", for: .normal)
            raceButton.setTitleColor(.placeholderText, for: .normal)
        }
    }

    private func showOptionPicker(
        title: String,
        options: [String],
        selectedIndex: Int?,
        onSelect: @escaping (Int) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (index, option) in options.enumerated() {
            let prefix = index == selectedIndex ? "✓ " : ""
            alert.addAction(UIAlertAction(title: "\(prefix)\(option)", style: .default) { _ in
                onSelect(index)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = title == "Age Range" ? ageRangeButton : raceButton
            popover.sourceRect = (title == "Age Range" ? ageRangeButton : raceButton).bounds
        }
        present(alert, animated: true)
    }
    
    private func showAlert(message: String) {
        let alert = UIAlertController(title: "Alert", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITextFieldDelegate
extension RespondentInfoViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        activeTextField = textField
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        activeTextField = nil
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Move to next field or dismiss keyboard
        switch textField {
        case nameTextField:
            emailTextField.becomeFirstResponder()
        case emailTextField:
            locationTextField.becomeFirstResponder()
        case locationTextField:
            textField.resignFirstResponder()
        default:
            textField.resignFirstResponder()
        }
        return true
    }
}
