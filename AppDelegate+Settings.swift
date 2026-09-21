// The Settings window: entering, saving and removing the API key, and the alert preference.

import Cocoa

extension AppDelegate {
    @objc func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        keyField?.stringValue = ""
        setKeyStatus(apiKey == nil ? "No key saved" : "A key is saved in your Keychain", warning: false)
        removeButton?.isEnabled = apiKey != nil
        notifyCheck?.state = notifyEnabled ? .on : .off
        refreshMeterPicker()
        loadMeterChoices()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() {
        let heading = NSTextField(labelWithString: "Octopus API key")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let field = NSSecureTextField()
        field.placeholderString = "sk_live_…"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.keyEquivalent = "\r"
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey))
        let keyRow = NSStackView(views: [field, save, remove])
        keyRow.spacing = 8

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let meterHeading = NSTextField(labelWithString: "Meter")
        meterHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let picker = NSPopUpButton()
        picker.target = self
        picker.action = #selector(meterChanged(_:))
        picker.addItem(withTitle: "Loading…")
        picker.isEnabled = false

        let check = NSButton(
            checkboxWithTitle: "Alert 10 minutes before the cheap rate starts", target: self,
            action: #selector(toggleNotify(_:)))
        let test = NSButton(title: "Send Test Alert", target: self, action: #selector(testAlert))

        let stack = NSStackView(views: [heading, keyRow, status, meterHeading, picker, check, test])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: status)
        stack.setCustomSpacing(20, after: picker)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Pin the stack inside a container so the 20pt margin holds on every side.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        container.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: container.fittingSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Octopus Settings"
        window.contentView = container
        window.setContentSize(container.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        keyField = field
        keyStatus = status
        notifyCheck = check
        removeButton = remove
        meterPicker = picker
    }

    /// Lists every import meter on the account so a multi-property account isn't guessed at.
    func refreshMeterPicker() {
        guard let picker = meterPicker else { return }
        picker.removeAllItems()
        if meterChoices.isEmpty {
            picker.addItem(withTitle: apiKey == nil ? "Add an API key first" : "Loading…")
            picker.isEnabled = false
            return
        }
        for choice in meterChoices { picker.addItem(withTitle: choice.label) }
        picker.isEnabled = meterChoices.count > 1
        if let current = MeterPreference.resolve(from: meterChoices),
            let index = meterChoices.firstIndex(of: current)
        {
            picker.selectItem(at: index)
        }
    }

    @objc func meterChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < meterChoices.count else { return }
        MeterPreference.save(meterChoices[index])
        // Everything downstream is meter-specific, so start both over.
        snapshot = nil
        usageSeries = UsageSeries()
        usageCache.removeAll()
        usageWeeksBack = 0
        clearUsageChart(placeholder: "Loading…")
        refresh(manual: true)
        if usageWindow?.isVisible == true { loadUsage() }
    }

    func loadMeterChoices() {
        guard let key = apiKey, meterChoices.isEmpty else { return }
        Task {
            guard
                let auth = try? await gql(
                    "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": key]),
                let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String,
                let found = try? await discoverMeters(token: token)
            else { return }
            meterChoices = found
            refreshMeterPicker()
        }
    }

    @objc func toggleNotify(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "notifyBeforeCheap")
    }

    @objc func removeKey() {
        let confirm = NSAlert()
        confirm.icon = makeAppIcon()
        confirm.messageText = "Remove the saved API key?"
        confirm.informativeText =
            "The app will stop updating until you enter a key again. You can copy a new one from your Octopus account."
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let status = Keychain.delete()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            setKeyStatus("Couldn't remove it: \(Keychain.message(status))", warning: true)
            return
        }
        apiKey = nil
        snapshot = nil
        lastError = "No API key set"
        removeButton?.isEnabled = false
        setKeyStatus("Key removed", warning: false)
        updateIcon()
    }

    func setKeyStatus(_ text: String, warning: Bool) {
        keyStatus?.stringValue = text
        keyStatus?.textColor = warning ? .systemRed : .secondaryLabelColor
        // A failure message wraps onto a second line, so let the window grow to fit it.
        settingsWindow?.setContentSize(settingsWindow?.contentView?.fittingSize ?? .zero)
    }

    @objc func saveKey() {
        let value = (keyField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let status = Keychain.save(value)
        // Use the key this session even if it couldn't be stored, but say so plainly.
        apiKey = value
        keyField?.stringValue = ""
        removeButton?.isEnabled = true
        if status == errSecSuccess {
            setKeyStatus("Key saved", warning: false)
        } else {
            setKeyStatus(
                "Couldn't save to your Keychain: \(Keychain.message(status)). The key works until you quit.",
                warning: true)
        }
        snapshot = nil
        lastError = nil
        meterChoices = []
        refresh(manual: true)
        loadMeterChoices()
    }
}
