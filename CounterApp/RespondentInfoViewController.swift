import UIKit

class RespondentInfoViewController: UIViewController {
    
    // MARK: - Properties
    var onInfoSubmitted: ((RespondentInfo) -> Void)?
    var onCancel: (() -> Void)?
    private var activeTextField: UITextField?
    private let allowedAgeRange = 0...100
    private var isAnonymousSurvey = false
    
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
    
    private let ageTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Age"
        textField.borderStyle = .roundedRect
        textField.font = UIFont.systemFont(ofSize: 16)
        textField.keyboardType = .numberPad
        return textField
    }()

    private let ageWarningLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Age must be 100 or younger"
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()
    
    private let genderSegmentedControl: UISegmentedControl = {
        let items = ["Male", "Female", "Other", "Prefer not"]
        let control = UISegmentedControl(items: items)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        return control
    }()
    
    private let phoneTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Phone Number"
        textField.borderStyle = .roundedRect
        textField.font = UIFont.systemFont(ofSize: 16)
        textField.keyboardType = .phonePad
        return textField
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
    private lazy var ageLabel = createLabel(text: "Age *")
    private lazy var phoneLabel = createLabel(text: "Phone Number *")
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
        setupKeyboardObservers()
        setupTextFieldDelegates()
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
        stackView.addArrangedSubview(ageTextField)
        stackView.addArrangedSubview(ageWarningLabel)
        stackView.addArrangedSubview(genderLabel)
        stackView.addArrangedSubview(genderSegmentedControl)
        stackView.addArrangedSubview(phoneLabel)
        stackView.addArrangedSubview(phoneTextField)
        stackView.addArrangedSubview(locationLabel)
        stackView.addArrangedSubview(locationTextField)
        stackView.addArrangedSubview(submitButton)
        
        // Add button action
        submitButton.addTarget(self, action: #selector(submitButtonTapped), for: .touchUpInside)
        anonymousButton.addTarget(self, action: #selector(anonymousButtonTapped), for: .touchUpInside)
        ageTextField.addTarget(self, action: #selector(ageTextDidChange), for: .editingChanged)
        stackView.setCustomSpacing(6, after: ageTextField)
        
        // Add tap gesture to dismiss keyboard
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }
    
    private func setupTextFieldDelegates() {
        nameTextField.delegate = self
        ageTextField.delegate = self
        phoneTextField.delegate = self
        locationTextField.delegate = self
        
        // Add toolbar with Done button for number pad
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))
        toolbar.setItems([UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), doneButton], animated: false)
        
        ageTextField.inputAccessoryView = toolbar
        phoneTextField.inputAccessoryView = toolbar
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
            ageTextField.heightAnchor.constraint(equalToConstant: 44),
            genderSegmentedControl.heightAnchor.constraint(equalToConstant: 32),
            phoneTextField.heightAnchor.constraint(equalToConstant: 44),
            locationTextField.heightAnchor.constraint(equalToConstant: 44),
            submitButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    // MARK: - Actions
    @objc private func submitButtonTapped() {
        let nameText = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phoneText = phoneTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ageText = ageTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard isAnonymousSurvey || !nameText.isEmpty else {
            showAlert(message: "Please enter name")
            return
        }

        let age = Int(ageText)
        guard isAnonymousSurvey || (!ageText.isEmpty && age != nil) else {
            showAlert(message: "Please enter a valid age")
            return
        }

        guard isAnonymousSurvey || allowedAgeRange.contains(age ?? -1) else {
            updateAgeWarning()
            showAlert(message: "Please enter an age from \(allowedAgeRange.lowerBound) to \(allowedAgeRange.upperBound)")
            return
        }
        
        guard isAnonymousSurvey || !phoneText.isEmpty else {
            showAlert(message: "Please enter phone number")
            return
        }
        
        guard let location = locationTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else {
            showAlert(message: "Please enter survey location")
            return
        }
        
        let genderOptions = ["Male", "Female", "Other", "Prefer not to say"]
        let gender = genderOptions[genderSegmentedControl.selectedSegmentIndex]
        
        let info = RespondentInfo(
            isAnonymous: isAnonymousSurvey,
            name: isAnonymousSurvey ? nil : nameText,
            age: isAnonymousSurvey ? nil : age,
            gender: gender,
            phone: isAnonymousSurvey ? nil : phoneText,
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

    @objc private func ageTextDidChange() {
        updateAgeWarning()
    }

    private func updateAnonymousSurveyUI() {
        anonymousButton.setImage(
            UIImage(systemName: isAnonymousSurvey ? "checkmark.square.fill" : "square"),
            for: .normal
        )

        nameLabel.isHidden = isAnonymousSurvey
        nameTextField.isHidden = isAnonymousSurvey
        ageLabel.isHidden = isAnonymousSurvey
        ageTextField.isHidden = isAnonymousSurvey
        ageWarningLabel.isHidden = true
        phoneLabel.isHidden = isAnonymousSurvey
        phoneTextField.isHidden = isAnonymousSurvey

        if isAnonymousSurvey {
            nameTextField.text = nil
            ageTextField.text = nil
            phoneTextField.text = nil
            ageTextField.textColor = .label
            activeTextField?.resignFirstResponder()
        }
    }

    private func updateAgeWarning() {
        let ageText = ageTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let age = Int(ageText)
        let shouldShowWarning = age.map { $0 > allowedAgeRange.upperBound } ?? false

        ageWarningLabel.isHidden = !shouldShowWarning
        ageTextField.textColor = shouldShowWarning ? .systemRed : .label
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
            ageTextField.becomeFirstResponder()
        case ageTextField:
            phoneTextField.becomeFirstResponder()
        case phoneTextField:
            locationTextField.becomeFirstResponder()
        case locationTextField:
            textField.resignFirstResponder()
        default:
            textField.resignFirstResponder()
        }
        return true
    }
}
