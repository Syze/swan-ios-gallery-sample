import UIKit
import Security

// Swan sign-in for the Gallery Pick reference host.
//
// A session token comes from `POST /auth/session`, which takes the publishable
// *and* the secret key. In a shipped app that call belongs on your own server —
// the app receives only the token — and the keys below never ship. This sample
// calls the API directly because it is a test host.
//
// At launch `ViewController` shows `SwanSessionViewController`. With a saved
// token that has more than a minute left it offers that email and a Continue
// button, and a way to sign in with another email instead; otherwise it asks
// for email and name. The page loads once there is a token.

enum SwanSessionConfig {
    /// The API the token is minted on. It must be the environment the web bundle
    /// talks to (`API_BASE_URL` in the package), or every upload is refused.
    static let apiBase = URL(string: "https://develop.api.swanvision.ai")!
    static let publishableKey = "sw_pk_6ceee992d2964a4088aba4577ebc802a"
    static let secretKey = "sw_sk_5f85098a56fd439fae417a672cf71763"

    /// A token this close to expiry counts as gone, so a scan does not start on a
    /// token that dies during the upload.
    static let expiryMargin: TimeInterval = 60
}

struct SwanSession: Codable {
    var email: String
    var name: String
    var token: String
    /// What the API said, when it said anything. The token's own `exp` wins.
    var expiresAt: Date?

    /// When the token stops working, or nil when neither the token nor the API
    /// said — treated as alive.
    var validUntil: Date? {
        if let exp = SwanJWT.claims(token)?["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        return expiresAt
    }

    /// The email inside the token, when it carries one. The gallery runs for this
    /// address: it is the one the API attributes uploads to. Session tokens carry
    /// a plain `email`; older Auth0-issued ones used the namespaced claim.
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

    // MARK: Keychain — one generic-password item, this device only.

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

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

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

enum SwanSessionClient {
    /// `POST /auth/session` → a token for this email. The name is required by the
    /// API; it labels the session, nothing more.
    static func createSession(email: String, name: String) async throws -> SwanSession {
        var request = URLRequest(url: SwanSessionConfig.apiBase.appendingPathComponent("auth/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "publishableKey": SwanSessionConfig.publishableKey,
            "secretKey": SwanSessionConfig.secretKey,
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

/// Email and name, one button — or, with a live session, the email that is
/// signed in and a Continue button, with the form one tap away for another
/// email. Signing in again replaces the saved session.
final class SwanSessionViewController: UIViewController, UITextFieldDelegate {
    var onSignedIn: ((SwanSession) -> Void)?

    /// A session that is still valid, shown first so a tester taps once.
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

        // The signed-in state: who, and one button.
        signedInLabel.font = .preferredFont(forTextStyle: .headline)
        signedInLabel.numberOfLines = 0

        var continueConfig = UIButton.Configuration.filled()
        continueConfig.title = "Continue"
        continueConfig.cornerStyle = .large
        continueConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        continueButton.configuration = continueConfig
        continueButton.addTarget(self, action: #selector(continueExisting), for: .touchUpInside)

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

        var config = UIButton.Configuration.filled()
        config.title = "Continue"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config
        button.addTarget(self, action: #selector(submit), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        // Which API this signs into, so a tester never wonders which keys ran.
        let footer = UILabel()
        footer.text = "Signs in to \(SwanSessionConfig.apiBase.host ?? "Swan"). The session is kept on this phone until it expires."
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if existing == nil { emailField.becomeFirstResponder() }
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
        title_.text = "Sign in to Swan"
        subtitle.text = "Enter your details to create a Swan session."
        for v in [signedInLabel, continueButton, switchButton] { v.isHidden = true }
        for v in [emailField, nameField, button] { v.isHidden = false }
        errorLabel.isHidden = true
        if isViewLoaded, view.window != nil { emailField.becomeFirstResponder() }
    }

    @objc private func continueExisting() {
        guard let existing = existing else { return }
        onSignedIn?(existing)
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
