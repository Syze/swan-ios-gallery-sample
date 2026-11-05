// Swan sign-in: gets a session token for an email and keeps it in the Keychain.

import UIKit
import Security

// MARK: - Settings
// The key below is a placeholder for this sample. A real app should mint session
// tokens on its own server and never ship an API key inside the app.

enum SwanSessionConfig {
    /// Where the token is minted, per build (see `SwanEnvironment`).
    static let sessionURL = SwanEnvironment.current.sessionURL
    /// The sample's key for this build (see the note above).
    static let publishableKey = SwanEnvironment.current.publishableKey

    /// A token this close to expiry counts as gone, so a scan does not start on a
    /// token that dies during the upload.
    static let expiryMargin: TimeInterval = 60
    /// A token with less than this left when the page (re)loads is minted again first, so a whole
    /// run (scan, upload, a build waited on for up to twenty minutes) fits inside it.
    static let renewMargin: TimeInterval = 50 * 60
}

// MARK: - Session

/// A signed-in session, saved in the Keychain on this phone.
struct SwanSession: Codable {
    var email: String
    var name: String
    var token: String
    /// Expiry as the API reported it, if it did. The token's own `exp` wins.
    var expiresAt: Date?

    /// When the token stops working, or nil when neither the token nor the API
    /// said — treated as alive.
    var validUntil: Date? {
        if let exp = SwanJWT.claims(token)?["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        return expiresAt
    }

    /// The email inside the token, plain or namespaced claim. The gallery uses it,
    /// because the API files uploads under this address.
    var tokenEmail: String? {
        let claims = SwanJWT.claims(token)
        return (claims?["email"] as? String) ?? (claims?["https://api.swanvision.ai/email"] as? String)
    }

    /// The saved session, if it is still worth using.
    static func restoreIfAlive() -> SwanSession? {
        guard var saved = load() else { return nil }
        if let until = saved.validUntil, until.timeIntervalSinceNow < SwanSessionConfig.expiryMargin {
            return nil
        }
        if let email = saved.tokenEmail { saved.email = email }
        return saved
    }

    // MARK: - Keychain (one item, this device only)

    private static let service = "co.getswan.gallery.session"
    private static let account = "session"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SecItemDelete(Self.query as CFDictionary)
        var item = Self.query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> SwanSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SwanSession.self, from: data)
    }
}

// MARK: - Token

/// Reads a JWT's payload without verifying it — the API verifies; this only
/// decides whether to ask for a new one and which email the token is for.
enum SwanJWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum SwanSessionError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}

// MARK: - Network

enum SwanSessionClient {
    /// `POST` to the session endpoint → a token for this email. The name is
    /// required by the API; it labels the session, nothing more.
    static func createSession(email: String, name: String) async throws -> SwanSession {
        var request = URLRequest(url: SwanSessionConfig.sessionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "publishableKey": SwanSessionConfig.publishableKey,
            "userEmail": email,
            "userName": name,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status),
              let token = json?["sessionToken"] as? String, !token.isEmpty else {
            throw SwanSessionError.server((json?["message"] as? String) ?? "Sign-in failed (HTTP \(status))")
        }
        return SwanSession(email: email, name: name, token: token, expiresAt: Self.date(from: json?["expiresAt"]))
    }

    /// `expiresAt` as the API sends it: ISO-8601 with or without fractions, or a
    /// number of seconds or milliseconds. Anything else is simply unknown.
    private static func date(from value: Any?) -> Date? {
        if let text = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        return nil
    }
}

// MARK: - Sign-in screen

/// Asks for email and name; with a live session, shows that email and a Continue
/// button instead. Signing in again replaces the saved session.
final class SwanSessionViewController: UIViewController, UITextFieldDelegate {
    var onSignedIn: ((SwanSession) -> Void)?
    /// The gallery page failed after a session existed. Reloads that page only.
    var onRetryPage: (() -> Void)?

    /// A session that is still valid, shown first so the user taps once.
    private let existing: SwanSession?

    private let title_ = UILabel()
    private let subtitle = UILabel()
    private let signedInLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let emailField = UITextField()
    private let nameField = UITextField()
    private let errorLabel = UILabel()
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var busy = false
    /// The last Continue opened a session, and the gallery page then failed.
    private var pageFailed = false

    init(existing: SwanSession?) {
        self.existing = existing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true

        title_.font = .preferredFont(forTextStyle: .largeTitle)
        title_.font = UIFont.systemFont(ofSize: title_.font.pointSize, weight: .bold)
        title_.adjustsFontForContentSizeCategory = true

        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        // Signed-in view: the email and one button.
        signedInLabel.font = .preferredFont(forTextStyle: .headline)
        signedInLabel.numberOfLines = 0

        setUpContinueButton(continueButton, action: #selector(continueExisting))

        var switchConfig = UIButton.Configuration.plain()
        switchConfig.title = "Use a different email"
        switchButton.configuration = switchConfig
        switchButton.addTarget(self, action: #selector(showForm), for: .touchUpInside)

        // The form.
        for (field, placeholder) in [(emailField, "Email"), (nameField, "Name")] {
            field.placeholder = placeholder
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.autocorrectionType = .no
            field.delegate = self
            field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.returnKeyType = .next
        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .go

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        setUpContinueButton(button, action: #selector(submit))

        spinner.hidesWhenStopped = true

        // Shows which server this signs in to.
        let footer = UILabel()
        footer.text = "Signs in to \(SwanSessionConfig.sessionURL.host ?? "Swan"). The session is kept on this phone until it expires."
        footer.font = .preferredFont(forTextStyle: .caption1)
        footer.textColor = .tertiaryLabel
        footer.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title_, subtitle, signedInLabel, continueButton, switchButton,
                                                   emailField, nameField, errorLabel, button, spinner, footer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(20, after: errorLabel)
        stack.setCustomSpacing(20, after: switchButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
        ])

        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing)))

        if let existing = existing {
            showSignedIn(existing)
        } else {
            showForm()
        }
    }

    /// Styles `button` as the screen's large filled "Continue" button and points it at `action`.
    private func setUpContinueButton(_ button: UIButton, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = "Continue"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if existing == nil { emailField.becomeFirstResponder() }
    }

    /// Session saved: shows a spinner until the gallery page is ready. Main thread.
    func beginOpeningGallery() {
        pageFailed = false
        busy = true
        view.endEditing(true)
        errorLabel.isHidden = true
        continueButton.isEnabled = false
        button.isEnabled = false
        switchButton.isEnabled = false
        emailField.isEnabled = false
        nameField.isEnabled = false
        button.configuration?.title = "Opening the gallery…"
        continueButton.configuration?.title = "Opening the gallery…"
        spinner.isHidden = false
        spinner.startAnimating()
    }

    /// The page never became ready. The session is kept; Try again reloads the page.
    func showPageError(_ message: String) {
        busy = false
        pageFailed = true
        errorLabel.text = message
        errorLabel.isHidden = false
        spinner.stopAnimating()
        emailField.isEnabled = true
        nameField.isEnabled = true
        switchButton.isEnabled = true
        button.isEnabled = true
        continueButton.isEnabled = true
        if !button.isHidden { button.configuration?.title = "Try again" }
        if !continueButton.isHidden { continueButton.configuration?.title = "Try again" }
    }

    private func showSignedIn(_ session: SwanSession) {
        title_.text = "Welcome back"
        subtitle.text = "You are signed in. Continue, or sign in with another email."
        let until = session.validUntil.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }
        signedInLabel.text = session.email + (until.map { " · valid until \($0)" } ?? "")
        for v in [signedInLabel, continueButton, switchButton] { v.isHidden = false }
        for v in [emailField, nameField, errorLabel, button, spinner] { v.isHidden = true }
    }

    @objc private func showForm() {
        pageFailed = false
        button.configuration?.title = "Continue"
        continueButton.configuration?.title = "Continue"
        title_.text = "Sign in to Swan"
        subtitle.text = "Enter your details to create a Swan session."
        for v in [signedInLabel, continueButton, switchButton] { v.isHidden = true }
        for v in [emailField, nameField, button] { v.isHidden = false }
        errorLabel.isHidden = true
        if isViewLoaded, view.window != nil { emailField.becomeFirstResponder() }
    }

    @objc private func continueExisting() {
        if pageFailed {
            retryPage()
            return
        }
        guard let existing = existing else { return }
        onSignedIn?(existing)
    }

    private func retryPage() {
        beginOpeningGallery()
        onRetryPage?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            nameField.becomeFirstResponder()
        } else {
            submit()
        }
        return true
    }

    @objc private func submit() {
        if pageFailed {
            retryPage()
            return
        }
        guard !busy else { return }
        let email = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count >= 5 else { return show(error: "Enter a valid email address.") }
        guard !name.isEmpty else { return show(error: "Enter your name.") }

        view.endEditing(true)
        setBusy(true)
        Task { @MainActor in
            do {
                // A new sign-in replaces whatever was saved, token and email alike.
                let session = try await SwanSessionClient.createSession(email: email, name: name)
                session.save()
                setBusy(false)
                onSignedIn?(session)
            } catch {
                setBusy(false)
                show(error: error.localizedDescription)
            }
        }
    }

    private func show(error: String) {
        errorLabel.text = error
        errorLabel.isHidden = false
    }

    private func setBusy(_ value: Bool) {
        busy = value
        errorLabel.isHidden = value || errorLabel.text == nil
        button.isEnabled = !value
        button.configuration?.title = value ? "Signing in…" : "Continue"
        if value { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}
